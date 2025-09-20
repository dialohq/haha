module StreamMap = Map.Make (Int32)

type 'peer t = {
  map : 'peer Stream.t StreamMap.t;
  last_peer_stream : Stream_identifier.t;
  last_local_stream : Stream_identifier.t;
  max_streams : int;
  handle_headers : end_stream:bool -> Headers.t -> 'peer Stream.transition;
}

let init_client : int -> Stream.client_peer t =
 fun max_streams ->
  {
    map = StreamMap.empty;
    last_peer_stream = 0l;
    last_local_stream = -1l;
    max_streams;
    handle_headers = Stream.receive_headers_client;
  }

let init_server : request_handler:Reqd.handler -> int -> Stream.server_peer t =
 fun ~request_handler max_streams ->
  {
    map = StreamMap.empty;
    last_peer_stream = -1l;
    last_local_stream = 0l;
    max_streams;
    handle_headers = Stream.receive_headers_server ~request_handler;
  }

let update_max_streams : int -> 'p t -> 'p t =
 fun max_streams t -> { t with max_streams }

let update_ids : Stream_identifier.t -> 'p t -> 'p t =
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

(*

A general function would be good to do something before the specific processing function and after every on of them, like those actions:
  - before/after -> update last ids
  - after -> clean up all terminated/idle streams from the map

*)

let read_data :
    id:Stream_identifier.t ->
    end_stream:bool ->
    Cstruct.t ->
    'a t ->
    ('a t, Error_code.t * string) result =
 fun ~id ~end_stream data t ->
  match StreamMap.find_opt id t.map with
  | Some stream ->
      let res = Stream.read_data ~end_stream data stream in
      Result.map
        (fun new_stream ->
          let map = StreamMap.add id new_stream t.map in
          update_ids id { t with map })
        res
  | None ->
      let stream =
        if id > t.last_local_stream then Stream.create_idle ~id
        else Stream.create_terminated ~id
      in

      let res = Stream.read_data ~end_stream data stream in
      Result.map
        (fun _ ->
          (* NOTE: should we update the map or no here? *)
          t)
        res

let receive_headers :
    id:Stream_identifier.t ->
    end_stream:bool ->
    Headers.t ->
    'a t ->
    ('a t, Error_code.t * string) result =
 fun ~id ~end_stream headers t ->
  match StreamMap.find_opt id t.map with
  | Some stream ->
      let res = t.handle_headers ~end_stream headers stream in
      Result.map
        (fun new_stream ->
          let map = StreamMap.add id new_stream t.map in
          update_ids id { t with map })
        res
  | None ->
      let stream =
        if id > t.last_local_stream then Stream.create_idle ~id
        else Stream.create_terminated ~id
      in

      let res = t.handle_headers ~end_stream headers stream in
      Result.map
        (fun new_stream ->
          let map = StreamMap.add id new_stream t.map in
          update_ids id { t with map })
        res

let receive_rst :
    id:Stream_identifier.t ->
    Error_code.t ->
    'a t ->
    ('a t, Error_code.t * string) result =
 fun ~id code t ->
  match StreamMap.find_opt id t.map with
  | Some stream ->
      let res = Stream.receive_rst code stream in
      Result.map
        (fun new_stream ->
          let map = StreamMap.add id new_stream t.map in
          update_ids id { t with map })
        res
  | None ->
      let stream =
        if id > t.last_local_stream then Stream.create_idle ~id
        else Stream.create_terminated ~id
      in

      let res = Stream.receive_rst code stream in
      Result.map
        (fun new_stream ->
          let map = StreamMap.add id new_stream t.map in
          update_ids id { t with map })
        res

(*
let count_active : _ t -> int =
 fun { map; _ } ->
  StreamMap.fold
    (fun _ (v : _ Stream.t) acc ->
      match v with State (Closed _ | Idle) -> acc | _ -> acc + 1)
    map 0

let count_open t =
  StreamMap.fold
    (fun _ (v : _ Stream.t) acc ->
      match v with State (Open _) | State (HalfClosed _) -> acc + 1 | _ -> acc)
    t.map 0

let finalize_stream : ?err:Error.t -> 'p Stream.t -> unit =
 fun ?err (State s) ->
  match s with
  | Open { on_close; context; error_handler; _ }
  | HalfClosed
      ( Remote { on_close; context; error_handler; _ }
      | Local { on_close; context; error_handler; _ } )
  | Reserved
      ( Local { on_close; context; error_handler; _ }
      | Remote { on_close; context; error_handler; _ } ) ->
      let final_ctx =
        match err with Some err -> error_handler context err | None -> context
      in
      on_close final_ctx
  | _ -> ()

let close_stream : ?err:Error.t -> Stream_identifier.t -> 'p t -> 'p t =
 fun ?err id t ->
  let map =
    StreamMap.update id
      (fun s ->
        Option.iter (finalize_stream ?err) s;
        None)
      t.map
  in

  { t with map }

let close_all : ?err:Error.t -> _ t -> unit =
 fun ?err { map; _ } -> StreamMap.iter (fun _ -> finalize_stream ?err) map

let update_closing_streams : _ t -> _ t =
 fun t ->
  let map =
    StreamMap.filter_map
      (fun _ -> function
        | Stream.State (Closed Terminating) ->
            Some (Stream.State (Closed Terminated))
        | State (Closed Terminated) -> None
        | other -> Some other)
      t.map
  in
  { t with map }

let stream_transition : Stream_identifier.t -> 'p Stream.t -> 'p t -> 'p t =
 fun id stream t ->
  let map =
    StreamMap.update id
      (function
        | Some (Stream.State (Closed Terminated)) -> None
        | Some _ | None -> Some stream)
      t.map
  in

  { t with map } |> update_last_id id

let update_stream_state :
    ?writer:Writer.t ->
    Stream_identifier.t ->
    'p Stream.transition ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ?writer id update t ->
  let x = StreamMap.find_opt id t.map in
  let stream : _ Stream.t =
    match x with
    | None when id > t.last_local_stream && id > t.last_peer_stream ->
        State Idle
    | None -> State (Closed Terminated)
    | Some stream -> stream
  in
  let map =
    match update stream with
    | Ok new_stream -> Ok (StreamMap.add id new_stream t.map)
    | Error (StreamError (id, code) as err) ->
        Option.iter (Writer.rst_stream id code) writer;
        finalize_stream ~err stream;
        Ok (StreamMap.add id (Stream.State (Closed Terminating)) t.map)
    | Error (ConnectionError err) -> Error err
  in
  Result.map (fun map -> { t with map }) map

let read_data :
    end_stream:bool ->
    writer:Writer.t ->
    data:Cstruct.t ->
    Stream_identifier.t ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ~end_stream ~writer ~data id ->
  let f : _ Stream.transition =
    let open Error in
    fun (State state) ->
      let send_update increment = Writer.window_update ~increment id writer in
      match state with
      | Closed Terminating -> Ok (State state)
      | Idle ->
          Error
            (conn_prot_err ProtocolError
               "DATA frame received on closed stream! Stream ID %li" id)
      | HalfClosed (Remote _) -> Error (stream_prot_err id StreamClosed)
      | Reserved _ ->
          Error
            (conn_prot_err ProtocolError
               "DATA frame received on reserved stream. Stream ID %li" id)
      | Closed Terminated ->
          Error
            (conn_prot_err StreamClosed
               "DATA frame received on closed stream! Stream ID %li" id)
      | Open
          ({
             readers = BodyReader reader;
             writers;
             error_handler;
             on_close;
             context;
             flow;
           } as state') ->
          let new_context =
            match (end_stream, Cstruct.is_empty data) with
            | false, _ -> reader context (`Data data)
            | true, false ->
                reader (reader context (`Data data)) (`End Headers.empty)
            | true, true -> reader context (`End Headers.empty)
          in
          let flow =
            Flow_control.receive_data ~send_update flow
              (Cstruct.length data |> Int32.of_int)
          in

          let new_state : _ Stream.state =
            if end_stream then
              HalfClosed
                (Remote
                   {
                     writers;
                     error_handler;
                     on_close;
                     context = new_context;
                     flow;
                   })
            else Open { state' with flow; context = new_context }
          in

          Ok (State new_state)
      | HalfClosed
          (Local
             ({ readers = BodyReader reader; on_close; context; flow; _ } as
              state')) ->
          let new_context =
            match (end_stream, Cstruct.is_empty data) with
            | false, _ -> reader context (`Data data)
            | true, false ->
                reader (reader context (`Data data)) (`End Headers.empty)
            | true, true -> reader context (`End Headers.empty)
          in
          let flow =
            Flow_control.receive_data ~send_update flow
              (Cstruct.length data |> Int32.of_int)
          in

          let new_state : _ Stream.state =
            if end_stream then (
              on_close new_context;
              Closed Terminating)
            else HalfClosed (Local { state' with flow; context = new_context })
          in

          Ok (State new_state)
      | _ -> Error (stream_prot_err id ProtocolError)
  in

  update_stream_state ~writer id f

let receive_rst :
    error_code:Error_code.t ->
    Stream_identifier.t ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ~error_code id ->
  let open Error in
  let f : _ Stream.transition =
   fun (State state) ->
    match state with
    | Closed Terminating -> Ok (State state)
    | Idle ->
        Error
          (conn_prot_err Error_code.ProtocolError
             "RST_STREAM received on a idle stream")
    | Closed Terminated ->
        Error
          (conn_prot_err Error_code.StreamClosed
             "RST_STREAM received on a closed stream!")
    | _ -> Error (stream_prot_err id error_code)
  in
  update_stream_state id f

let receive_window_update :
    writer:Writer.t ->
    Stream_identifier.t ->
    int32 ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ~writer id increment ->
  let f : _ Stream.transition =
   fun (State state) ->
    match state with
    | Closed Terminating -> Ok (State state)
    | Closed Terminated -> Error (Error.stream_prot_err id StreamClosed)
    | Open ({ flow; _ } as state') ->
        Ok
          (State
             (Open
                { state' with flow = Flow_control.incr_out_flow flow increment }))
    | Reserved (Local ({ flow; _ } as state')) ->
        Ok
          (State
             (Reserved
                (Local
                   {
                     state' with
                     flow = Flow_control.incr_out_flow flow increment;
                   })))
    | Reserved (Remote ({ flow; _ } as state')) ->
        Ok
          (State
             (Reserved
                (Remote
                   {
                     state' with
                     flow = Flow_control.incr_out_flow flow increment;
                   })))
    | HalfClosed (Local ({ flow; _ } as state')) ->
        Ok
          (State
             (HalfClosed
                (Local
                   {
                     state' with
                     flow = Flow_control.incr_out_flow flow increment;
                   })))
    | HalfClosed (Remote ({ flow; _ } as state')) ->
        Ok
          (State
             (HalfClosed
                (Remote
                   {
                     state' with
                     flow = Flow_control.incr_out_flow flow increment;
                   })))
    | Idle ->
        Error
          (Error.conn_prot_err ProtocolError "unexpected WINDOW_UPDATE[%li]" id)
  in

  update_stream_state ~writer id f

let all_closed : _ t -> bool =
 fun { map; _ } ->
  StreamMap.for_all
    (fun _ (stream : _ Stream.t) ->
      match stream with State (Closed _) -> true | _ -> false)
    map

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
 (* FIXME: do smth with on_flush, idk *)
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
            | `Interim _ -> t)
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

let receive_trailers :
    writer:Writer.t ->
    headers:Headers.t ->
    Stream_identifier.t ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ~writer ~headers id t ->
  let f : _ Stream.transition =
    let open Error in
    fun (State state) ->
      match state with
      | Closed Terminating -> Ok (State state)
      | Open
          {
            readers = BodyReader reader;
            writers;
            error_handler;
            on_close;
            context;
            flow;
          } ->
          let new_context = reader context (`End headers) in
          Ok
            (State
               (HalfClosed
                  (Remote
                     {
                       writers;
                       error_handler;
                       on_close;
                       context = new_context;
                       flow;
                     })))
      | HalfClosed (Local { readers = BodyReader reader; on_close; context; _ })
        ->
          let new_context = reader context (`End headers) in

          on_close new_context;
          Ok (State (Closed Terminated))
      | Reserved _ -> Error (stream_prot_err id Error_code.StreamClosed)
      | Idle ->
          Error
            (conn_prot_err ProtocolError
               "HEADERS frame received on idle stream! Stream ID %li" id)
      | Closed Terminated ->
          Error
            (conn_prot_err Error_code.StreamClosed
               "HEADERS received on a closed stream")
      | HalfClosed (Remote _) -> Error (stream_prot_err id StreamClosed)
      | Open _ | HalfClosed (Local _) ->
          Error (stream_prot_err id Error_code.ProtocolError)
  in

  update_stream_state ~writer id f t

let receive_request :
    writer:Writer.t ->
    request_handler:Reqd.handler ->
    pseudo:Headers.Pseudo.request_pseudos ->
    end_stream:bool ->
    headers:Headers.t ->
    max_streams:int32 ->
    Stream_identifier.t ->
    server_peer t ->
    (server_peer t, Error.connection_error) result =
 fun ~writer ~request_handler ~pseudo ~end_stream ~headers ~max_streams id t ->
  let f : server_peer Stream.transition =
    let open Error in
    fun (State state) -
      match state with
      | Closed Terminating -> Ok (State state)
      | Idle ->
          let open_streams = count_open t in
          if open_streams < Int32.to_int max_streams then
            let reqd =
              {
                Reqd.meth = Method.of_string pseudo.meth;
                path = pseudo.path;
                authority = pseudo.authority;
                scheme = pseudo.scheme;
                headers;
              }
            in

            let (ReqdHandle
                   {
                     body_reader = reader;
                     response_writer;
                     error_handler;
                     on_close;
                     context;
                   }) =
              request_handler reqd
            in

            let new_stream_state : server_peer Stream.t =
              if end_stream then
                State
                  (HalfClosed
                     (Remote
                        {
                          writers = WritingResponse response_writer;
                          error_handler;
                          on_close;
                          context;
                          flow = Flow_control.initial;
                        }))
              else
                State
                  (Open
                     {
                       readers = BodyReader reader;
                       writers = WritingResponse response_writer;
                       error_handler;
                       on_close;
                       context;
                       flow = Flow_control.initial;
                     })
            in

            Ok new_stream_state
          else
            Error
              (conn_prot_err Error_code.ProtocolError
                 "MAX_CONCURRENT_STREAMS setting reached")
      | Open _ | HalfClosed (Local _) ->
          Error (stream_prot_err id Error_code.ProtocolError)
      | Reserved _ ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "HEADERS received on reserved stream")
      | HalfClosed (Remote _) | Closed Terminated ->
          Error
            (conn_prot_err Error_code.StreamClosed
               "HEADERS received on closed stream")
  in

  update_stream_state ~writer id f t

let receive_response :
    pseudo:Headers.Pseudo.response_pseudos ->
    end_stream:bool ->
    headers:Headers.t ->
    writer:Writer.t ->
    Stream_identifier.t ->
    client_peer t ->
    (client_peer t, Error.connection_error) result =
 fun ~pseudo ~end_stream ~headers ~writer id t ->
  let response () : _ Response.t =
    match Status.of_code pseudo.status with
    | #Status.informational as status -> `Interim { status; headers }
    | status -> `Final { status; headers; body_writer = None }
  in
  let is_final =
    match Status.of_code pseudo.status with
    | #Status.informational -> false
    | _ -> true
  in

  let f : client_peer Stream.transition =
    let open Error in
    fun (State state) ->
      match (state, is_final) with
      | Closed Terminating, _ -> Ok (State state)
      | ( Open
            ({ readers = AwaitingResponse response_handler; context; _ } as
             state'),
          false ) ->
          let _body_reader, context = response_handler context @@ response () in

          Ok (State (Open { state' with context }))
      | ( HalfClosed
            (Local
               ({ readers = AwaitingResponse response_handler; context; _ } as
                state')),
          false ) ->
          let _body_reader, context = response_handler context @@ response () in

          Ok (State (HalfClosed (Local { state' with context })))
      | ( Open
            {
              readers = AwaitingResponse response_handler;
              writers = body_writer;
              error_handler;
              on_close;
              context;
              flow;
            },
          true ) ->
          let body_reader, context = response_handler context @@ response () in

          let new_stream_state : client_peer Stream.t =
            match (body_reader, end_stream) with
            | None, _ ->
                Writer.rst_stream id NoError writer;
                on_close context;
                State (Closed Terminating)
            | Some _, true ->
                State
                  (HalfClosed
                     (Remote
                        {
                          writers = body_writer;
                          error_handler;
                          on_close;
                          context;
                          flow;
                        }))
            | Some body_reader, false ->
                State
                  (Open
                     {
                       readers = BodyReader body_reader;
                       writers = body_writer;
                       error_handler;
                       on_close;
                       context;
                       flow;
                     })
          in

          Ok new_stream_state
      | ( HalfClosed
            (Local
               {
                 readers = AwaitingResponse response_handler;
                 error_handler;
                 context;
                 on_close;
                 flow;
               }),
          true ) ->
          let body_reader, context = response_handler context @@ response () in

          let new_stream_state : client_peer Stream.t =
            match (end_stream, body_reader) with
            | false, None ->
                Writer.rst_stream id NoError writer;
                on_close context;
                State (Closed Terminating)
            | false, Some body_reader ->
                State
                  (HalfClosed
                     (Local
                        {
                          readers = BodyReader body_reader;
                          error_handler;
                          on_close;
                          context;
                          flow;
                        }))
            | true, _ ->
                on_close context;
                State (Closed Terminated)
          in

          Ok new_stream_state
      | Open { readers = BodyReader _; _ }, _
      | HalfClosed (Local { readers = BodyReader _; _ }), _ ->
          Error (stream_prot_err id ProtocolError)
      | Idle, _ ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "unexpected HEADERS response on idle stream")
      | Reserved _, _ ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "HEADERS received on reserved stream")
      | HalfClosed (Remote _), _ | Closed Terminated, _ ->
          Error
            (conn_prot_err Error_code.StreamClosed
               "HEADERS received on closed stream")
  in

  update_stream_state ~writer id f t

let write_request :
    writer:Writer.t -> request:Request.t -> client_peer t -> client_peer t =
 fun ~writer ~request t ->
  let (Request.Request
         {
           response_handler;
           body_writer;
           error_handler;
           initial_context;
           on_close;
           _;
         } as request) =
    request
  in
  let id = Int32.add t.last_local_stream 2l in
  Writer.request_headers id request writer;
  Writer.window_update id ~increment:Flow_control.initial_increment writer;
  let stream_state : _ Stream.t =
    match body_writer with
    | Some body_writer ->
        State
          (Open
             {
               readers = AwaitingResponse response_handler;
               writers = BodyWriter body_writer;
               error_handler;
               context = initial_context;
               on_close;
               flow = Flow_control.initial;
             })
    | None ->
        State
          (HalfClosed
             (Local
                {
                  readers = AwaitingResponse response_handler;
                  error_handler;
                  context = initial_context;
                  on_close;
                  flow = Flow_control.initial;
                }))
  in

  stream_transition id stream_state t
*)
