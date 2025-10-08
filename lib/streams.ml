module StreamMap = Map.Make (Int32)

type 'peer t = {
  map : 'peer Stream.t StreamMap.t;
  last_peer_stream : Stream_identifier.t;
  last_local_stream : Stream_identifier.t;
  max_local_streams : int32; [@warning "-69"]
  max_peer_streams : int32; [@warning "-69"]
  handle_headers : end_stream:bool -> Headers.t -> 'peer Stream.transition;
}

let init_client : int32 -> int32 -> Peer.client t =
 fun max_local_streams max_peer_streams ->
  {
    map = StreamMap.empty;
    last_peer_stream = 0l;
    last_local_stream = -1l;
    max_local_streams;
    max_peer_streams;
    handle_headers = Stream.receive_headers_client;
  }

let init_server :
    request_handler:Reqd.handler -> int32 -> int32 -> Peer.server t =
 fun ~request_handler max_local_streams max_peer_streams ->
  {
    map = StreamMap.empty;
    last_peer_stream = -1l;
    last_local_stream = 0l;
    max_local_streams;
    max_peer_streams;
    handle_headers = Stream.receive_headers_server ~request_handler;
  }

let last_peer_stream { last_peer_stream; _ } = last_peer_stream

let update_local_max : int32 -> 'a t -> 'a t =
 fun max_local_streams t -> { t with max_local_streams }

let update_peer_max : int32 -> 'a t -> 'a t =
 fun max_peer_streams t -> { t with max_peer_streams }

let active_streams : 'a t -> int =
 fun t ->
  StreamMap.fold
    (fun _ stream acc -> if Stream.is_active stream then acc + 1 else acc)
    t.map 0

let update_ids : Stream_identifier.t -> 'a t -> 'a t =
 fun id ({ last_peer_stream; last_local_stream; _ } as t) ->
  let open Stream_identifier in
  match
    (is_client id, is_client last_peer_stream, is_client last_local_stream)
  with
  | true, true, false | false, false, true ->
      { t with last_peer_stream = Int32.max last_peer_stream id }
  | true, false, true | false, true, false ->
      { t with last_local_stream = Int32.max last_local_stream id }
  | _, true, true | _, false, false ->
      (* initially we set odd and even values for those so this is unreachable *)
      assert false

let write_request :
    request:Request.t -> Peer.client t -> Peer.client t * Writer.write list =
 fun ~request t ->
  let id = Int32.add t.last_local_stream 2l in
  let new_stream, writes = Stream.init ~request id in
  let map = StreamMap.add id new_stream t.map in

  ({ t with map; last_local_stream = id }, writes)

let transition_stream :
    id:Stream_identifier.t ->
    'a Stream.transition ->
    'a t ->
    ('a t * Writer.write list, Error_code.t * string) result =
 fun ~id transition t ->
  let stream =
    match StreamMap.find_opt id t.map with
    | Some stream -> stream
    | None when id > t.last_local_stream -> Stream.create_idle ~id
    | None -> Stream.create_terminated ~id
  in

  let update_map (new_stream, writes) =
    let map =
      StreamMap.add id new_stream t.map
      |> StreamMap.filter (fun _ s -> not (Stream.is_eraseable s))
    in
    (* TODO: shouldn't event have anything like last_local_stream, everything is in the map *)
    (update_ids id { t with map }, writes)
  in

  Result.map update_map (transition stream)

let read_data ~id ~end_stream data =
  transition_stream ~id (Stream.read_data ~end_stream data)

let receive_headers ~id ~end_stream headers t =
  transition_stream ~id (t.handle_headers ~end_stream headers) t

let receive_rst ~id code = transition_stream ~id (Stream.receive_rst code)

let get_events : 'a t -> (unit -> 'a t -> 'a t * Writer.write list) list =
 fun t ->
  List.filter_map
    (fun (id, stream) ->
      Option.map
        (fun await_new () t ->
          let new_stream, writes = await_new () in
          let map = StreamMap.add id new_stream t.map in
          ({ t with map }, writes))
        (Stream.get_event stream))
    (StreamMap.bindings t.map)
(*
let body_writer_handler (type p) :
    state_on_data:p Stream.t ->
    state_on_end:p Stream.t ->
    writer:Writer.t ->
    max_frame_size:int ->
    _ Body.writer_payload ->
    Stream_identifier.t ->
    (unit -> unit) ->
    (unit -> unit) ->
    p t ->
    p t =
 fun ~state_on_data ~state_on_end ~writer ~max_frame_size payload id _on_flush
     on_close t ->
  (* let state = *)
  (*   { state with flush_thunk = Util.merge_thunks state.flush_thunk on_flush } *)
  (* in *)
  match payload with
  | `Data cs_list ->
      let distributed = Util.split_cstructs cs_list max_frame_size in
      List.iter (fun cs_list -> Writer.data id cs_list writer) distributed;

      stream_transition id state_on_data t
  | `End (Some cs_list, trailers) ->
      let send_trailers = Headers.length trailers > 0 in
      let distributed = Util.split_cstructs cs_list max_frame_size in
      List.iteri
        (fun i cs_list ->
          Writer.data
            ~end_stream:((not send_trailers) && i = List.length distributed - 1)
            id cs_list writer)
        distributed;

      if send_trailers then Writer.trailers id trailers writer;
      (match state_on_end with State (Closed _) -> on_close () | _ -> ());

      stream_transition id state_on_end t
  | `End (None, trailers) ->
      let send_trailers = Headers.length trailers > 0 in
      if send_trailers then Writer.trailers id trailers writer
      else Writer.data ~end_stream:true id [ Cstruct.empty ] writer;
      (match state_on_end with State (Closed _) -> on_close () | _ -> ());

      stream_transition id state_on_end t

let make_body_writer_transition (type p) :
    writer:Writer.t ->
    max_frame_size:int ->
    p Stream.t ->
    Stream_identifier.t ->
    (unit -> p t -> p t) option =
 fun ~writer ~max_frame_size (State state) id ->
  match state with
  | Open
      ({
         writers = BodyWriter body_writer;
         readers;
         error_handler;
         context;
         on_close;
         flow;
       } as state') ->
      Some
        (fun () ->
          let { Body.payload; on_flush; context = new_context } =
            body_writer context
          in

          body_writer_handler ~writer ~max_frame_size
            ~state_on_data:(State (Open { state' with context = new_context }))
            ~state_on_end:
              (State
                 (HalfClosed
                    (Local { context; error_handler; readers; on_close; flow })))
            payload id on_flush
            (fun () -> on_close context))
  | HalfClosed
      (Remote
         ({ writers = BodyWriter body_writer; on_close; context; _ } as state'))
    ->
      Some
        (fun () ->
          let { Body.payload; on_flush; context = new_context } =
            body_writer context
          in

          body_writer_handler ~writer ~max_frame_size
            ~state_on_data:
              (State (HalfClosed (Remote { state' with context = new_context })))
            ~state_on_end:(State (Closed Terminating)) payload id on_flush
            (fun () -> on_close context))
  | _ -> None

let make_response_writer_transition :
    writer:Writer.t ->
    server_peer Stream.t ->
    Stream_identifier.t ->
    (unit -> server_peer t -> server_peer t) option =
 fun ~writer (State state) id ->
  match state with
  | Open
      ({
         writers = WritingResponse response_writer;
         readers;
         error_handler;
         on_close;
         context;
         flow;
       } as state') ->
      Some
        (fun () ->
          let open Writer in
          let response = response_writer () in

          fun t ->
            response_headers id response writer;
            match response with
            | `Final { body_writer = Some body_writer; _ } ->
                window_update id ~increment:Flow_control.initial_increment
                  writer;
                stream_transition id
                  (State (Open { state' with writers = BodyWriter body_writer }))
                  t
            | `Final { body_writer = None; _ } ->
                window_update id ~increment:Flow_control.initial_increment
                  writer;
                stream_transition id
                  (State
                     (HalfClosed
                        (Local
                           { readers; error_handler; on_close; context; flow })))
                  t
            | `Interim _ -> t
            )
  | HalfClosed
      (Remote
         ({ writers = WritingResponse response_writer; on_close; context; _ } as
          state')) ->
      Some
        (fun () ->
          let open Writer in
          let response = response_writer () in

          fun t ->
            response_headers id response writer;
            match response with
            | `Final { body_writer = Some body_writer; _ } ->
                window_update id ~increment:Flow_control.initial_increment
                  writer;
                stream_transition id
                  (State
                     (HalfClosed
                        (Remote { state' with writers = BodyWriter body_writer })))
                  t
            | `Final { body_writer = None; _ } ->
                window_update id ~increment:Flow_control.initial_increment
                  writer;
                on_close context;
                stream_transition id (State (Closed Terminated)) t
            | `Interim _ -> t)
  | _ -> None

let body_writers_transitions :
    writer:Writer.t -> max_frame_size:int -> 'p t -> (unit -> 'p t -> 'p t) list
    =
 fun ~writer ~max_frame_size t ->
  StreamMap.fold
    (fun id stream acc ->
      match make_body_writer_transition ~writer ~max_frame_size stream id with
      | Some event -> event :: acc
      | None -> acc)
    t.map []

let response_writers_transitions :
    writer:Writer.t ->
    server_peer t ->
    (unit -> server_peer t -> server_peer t) list =
 fun ~writer t ->
  StreamMap.fold
    (fun id stream acc ->
      match make_response_writer_transition ~writer stream id with
      | Some event -> event :: acc
      | None -> acc)
    t.map []

*)
