module StreamMap = Map.Make (Int32)

type client_peer = private Client
type server_peer = private Server

type (_, 'c) writers =
  | BodyWriter : 'c Body.writer -> ('peer, 'c) writers
  | WritingResponse : 'c Response.response_writer -> (server_peer, 'c) writers

type (_, 'c) readers =
  | BodyReader : 'c Body.reader -> ('peer, 'c) readers
  | AwaitingResponse : 'c Response.handler -> (client_peer, 'c) readers

module Stream = struct
  type 'context error_handler = 'context -> Error.t -> 'context

  type ('peer, 'c) open_state = {
    readers : ('peer, 'c) readers;
    writers : ('peer, 'c) writers;
    error_handler : 'c error_handler;
    on_close : 'c -> unit;
    context : 'c;
    flow : Flow_control.t;
  }

  type ('peer, 'c) half_closed =
    | Remote of {
        writers : ('peer, 'c) writers;
        error_handler : 'c error_handler;
        on_close : 'c -> unit;
        context : 'c;
        flow : Flow_control.t;
      }
    | Local of {
        readers : ('peer, 'c) readers;
        error_handler : 'c error_handler;
        on_close : 'c -> unit;
        context : 'c;
        flow : Flow_control.t;
      }

  type 'context reserved =
    | Remote of {
        error_handler : 'context error_handler;
        on_close : 'context -> unit;
        context : 'context;
        flow : Flow_control.t;
      } [@warning "-37"]
    | Local of {
        error_handler : 'context error_handler;
        on_close : 'context -> unit;
        context : 'context;
        flow : Flow_control.t;
      } [@warning "-37"]

  type ('peer, 'c) state =
    | Idle
    | Reserved of 'c reserved
    | Open of ('peer, 'c) open_state
    | HalfClosed of ('peer, 'c) half_closed
    | Closed

  type 'peer t = State : ('peer, _) state -> 'peer t
  type 'p transition = 'p t -> ('p t, Error.t) result
end

type 'peer t = {
  map : 'peer Stream.t StreamMap.t;
  last_peer_stream : Stream_identifier.t;
  last_local_stream : Stream_identifier.t;
}

(* TODO: should manage last_*_stream values differently to avoid this. Should probobly be held in the general state or smth *)
let last_peer_stream : _ t -> int32 = fun t -> t.last_peer_stream

let initial : unit -> _ t =
 fun () ->
  {
    map = StreamMap.empty;
    last_peer_stream = Stream_identifier.connection;
    last_local_stream = Stream_identifier.connection;
  }

let count_active : _ t -> int = fun { map; _ } -> StreamMap.cardinal map

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

let find_stream : Stream_identifier.t -> 'p t -> 'p Stream.t =
 fun stream_id t ->
  match StreamMap.find_opt stream_id t.map with
  | None when stream_id > t.last_local_stream && stream_id > t.last_peer_stream
    ->
      Stream.State Idle
  | None -> State Closed
  | Some stream -> stream

let stream_transition : Stream_identifier.t -> 'p Stream.t -> 'p t -> 'p t =
 fun id stream t ->
  let map =
    StreamMap.update id
      (function
        (* TODO: update the last local/remote id *)
        | None -> Some stream
        | Some _ when stream = State Closed -> None
        | Some old -> Some old)
      t.map
  in

  { t with map }

let update_stream_state :
    Stream_identifier.t ->
    'p Stream.transition ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun id update t ->
  (*
  let map =
    StreamMap.update id
      (fun x ->
        let stream : _ Stream.t =
          match x with
          | None when id > t.last_local_stream && id > t.last_peer_stream ->
              State Idle
          | None -> State Closed
          | Some stream -> stream
        in

        match update stream with
        | Ok new_stream -> Some new_stream
        | Error (StreamError _ as err) ->
            finalize_stream ~err stream;
            None
        | Error (ConnectionError err) -> None)
      t.map
  in
  *)
  let stream_state = find_stream id t in

  match update stream_state with
  | Ok new_state -> Ok (stream_transition id new_state t)
  | Error (StreamError _ as err) -> Ok (close_stream ~err id t)
  | Error (ConnectionError err) -> Error err

let read_data :
    end_stream:bool ->
    send_update:(int32 -> unit) ->
    data:Bigstringaf.t ->
    Stream_identifier.t ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ~end_stream ~send_update ~data id ->
  let f : _ Stream.transition =
    let open Error in
    fun (State state) ->
      match state with
      | Idle | HalfClosed (Remote _) ->
          Error
            (conn_prot_err StreamClosed "DATA frame received on closed stream!")
      | Reserved _ ->
          Error
            (conn_prot_err ProtocolError
               "DATA frame received on reserved stream")
      | Closed ->
          Error
            (conn_prot_err StreamClosed "DATA frame received on closed stream!")
      | Open
          ({
             readers = BodyReader reader;
             writers;
             error_handler;
             on_close;
             context;
             flow;
           } as state') ->
          let new_context = reader context (`Data (Cstruct.of_bigarray data)) in
          let flow =
            Flow_control.receive_data ~send_update flow
              (Bigstringaf.length data |> Int32.of_int)
          in

          let new_state : _ Stream.state =
            if end_stream then
              HalfClosed
                (Remote
                   {
                     writers;
                     error_handler;
                     on_close;
                     context = reader new_context (`End []);
                     flow;
                   })
            else Open { state' with flow; context = new_context }
          in

          Ok (State new_state)
      | HalfClosed
          (Local
             ({ readers = BodyReader reader; on_close; context; flow; _ } as
              state')) ->
          let new_context = reader context (`Data (Cstruct.of_bigarray data)) in
          let flow =
            Flow_control.receive_data ~send_update flow
              (Bigstringaf.length data |> Int32.of_int)
          in

          let new_state : _ Stream.state =
            if end_stream then (
              on_close (reader new_context (`End []));
              Closed)
            else HalfClosed (Local { state' with flow; context = new_context })
          in

          Ok (State new_state)
      | _ -> Error (stream_prot_err id ProtocolError)
  in

  update_stream_state id f

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
    | Idle ->
        Error
          (conn_prot_err Error_code.ProtocolError
             "RST_STREAM received on a idle stream")
    | Closed ->
        Error
          (conn_prot_err Error_code.StreamClosed
             "RST_STREAM received on a closed stream!")
    | _ -> Error (stream_prot_err id error_code)
  in
  update_stream_state id f

let receive_window_update :
    Stream_identifier.t ->
    int32 ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun id increment ->
  let f : _ Stream.transition =
   fun (State state) ->
    match state with
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
    | _ ->
        Error
          (Error.conn_prot_err ProtocolError "unexpected WINDOW_UPDATE[%li]" id)
  in

  update_stream_state id f

let all_closed : _ t -> bool =
 fun { map; _ } ->
  StreamMap.for_all
    (fun _ (stream : _ Stream.t) ->
      match stream with State Closed -> true | _ -> false)
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
 fun ~state_on_data ~state_on_end ~writer ~max_frame_size res id _on_flush
     on_close ->
  fun t ->
   (* let state = *)
   (*   { state with flush_thunk = Util.merge_thunks state.flush_thunk on_flush } *)
   (* in *)
   match res with
   | `Data cs_list ->
       let distributed = Util.split_cstructs cs_list max_frame_size in
       List.iteri
         (fun _ (cs_list, len) ->
           Writer.write_data ~end_stream:false writer id len cs_list)
         distributed;

       stream_transition id state_on_data t
   | `End (Some cs_list, trailers) ->
       let send_trailers = List.length trailers > 0 in
       let distributed = Util.split_cstructs cs_list max_frame_size in
       List.iteri
         (fun i (cs_list, len) ->
           Writer.write_data
             ~end_stream:((not send_trailers) && i = List.length distributed - 1)
             writer id len cs_list)
         distributed;

       if send_trailers then Writer.write_trailers writer id trailers;
       (match state_on_end with State Closed -> on_close () | _ -> ());

       stream_transition id state_on_end t
   | `End (None, trailers) ->
       let send_trailers = List.length trailers > 0 in
       if send_trailers then Writer.write_trailers writer id trailers
       else Writer.write_data ~end_stream:true writer id 0 [ Cstruct.empty ];
       (match state_on_end with State Closed -> on_close () | _ -> ());

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
            ~state_on_end:(State Closed) payload id on_flush
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
            write_headers_response writer id response;
            match response with
            | `Final { body_writer = Some body_writer; _ } ->
                write_window_update writer id
                  Flow_control.WindowSize.initial_increment;
                stream_transition id
                  (State (Open { state' with writers = BodyWriter body_writer }))
                  t
            | `Final { body_writer = None; _ } ->
                write_window_update writer id
                  Flow_control.WindowSize.initial_increment;
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
            write_headers_response writer id response;
            match response with
            | `Final { body_writer = Some body_writer; _ } ->
                write_window_update writer id
                  Flow_control.WindowSize.initial_increment;
                stream_transition id
                  (State
                     (HalfClosed
                        (Remote { state' with writers = BodyWriter body_writer })))
                  t
            | `Final { body_writer = None; _ } ->
                write_window_update writer id
                  Flow_control.WindowSize.initial_increment;
                on_close context;
                stream_transition id (State Closed) t
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
    headers:Header.t list ->
    Stream_identifier.t ->
    'p t ->
    ('p t, Error.connection_error) result =
 fun ~headers id t ->
  let f : _ Stream.transition =
    let open Error in
    fun (State state) ->
      match state with
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
          Ok (State Closed)
      | Reserved _ -> Error (stream_prot_err id Error_code.StreamClosed)
      | Idle -> Error (stream_prot_err id Error_code.ProtocolError)
      | Closed | HalfClosed (Remote _) ->
          Error
            (conn_prot_err Error_code.StreamClosed
               "HEADERS received on a closed stream")
      | Open _ | HalfClosed (Local _) ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "received first HEADERS in stream %li with no pseudo-headers" id)
  in

  update_stream_state id f t

let receive_request :
    request_handler:Reqd.handler ->
    pseudo:Header.Pseudo.request_pseudo ->
    end_stream:bool ->
    headers:Header.t list ->
    max_streams:int32 ->
    Stream_identifier.t ->
    server_peer t ->
    (server_peer t, Error.connection_error) result =
 fun ~request_handler ~pseudo ~end_stream ~headers ~max_streams id t ->
  let f : server_peer Stream.transition =
    let open Error in
    fun (State state) ->
      match state with
      | Idle ->
          let open_streams = count_open t in
          if open_streams < Int32.to_int max_streams then
            let reqd =
              {
                Reqd.meth = Method.of_string pseudo.meth;
                path = pseudo.path;
                authority = pseudo.authority;
                scheme = pseudo.scheme;
                headers = Header.filter_pseudo headers;
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
      | HalfClosed (Remote _) | Closed ->
          Error
            (conn_prot_err Error_code.StreamClosed
               "HEADERS received on closed stream")
  in

  update_stream_state id f t

let receive_response :
    pseudo:Header.Pseudo.response_pseudo ->
    end_stream:bool ->
    headers:Header.t list ->
    writer:Writer.t ->
    Stream_identifier.t ->
    client_peer t ->
    (client_peer t, Error.connection_error) result =
 fun ~pseudo ~end_stream ~headers ~writer id t ->
  let headers = Header.filter_pseudo headers in
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
                Writer.write_rst_stream writer id NoError;
                on_close context;
                State Closed
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
                Writer.write_rst_stream writer id NoError;
                on_close context;
                State Closed
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
                State Closed
          in

          Ok new_stream_state
      | Open { readers = BodyReader _; _ }, _
      | HalfClosed (Local { readers = BodyReader _; _ }), _ ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "unexpected multiple non-informational HEADERS on stream %li" id)
      | Idle, _ ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "unexpected HEADERS response on idle stream")
      | Reserved _, _ ->
          Error
            (conn_prot_err Error_code.ProtocolError
               "HEADERS received on reserved stream")
      | HalfClosed (Remote _), _ | Closed, _ ->
          Error
            (conn_prot_err Error_code.StreamClosed
               "HEADERS received on closed stream")
  in

  update_stream_state id f t

(* FIXME: nahh *)
let get_next_id t = function
  | `Client ->
      if Stream_identifier.is_connection t.last_local_stream then 1l
      else Int32.add t.last_local_stream 2l
  | `Server ->
      if Stream_identifier.is_connection t.last_local_stream then 2l
      else Int32.add t.last_local_stream 2l

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
  let id = get_next_id t `Client in
  Writer.writer_request_headers writer id request;
  Writer.write_window_update writer id Flow_control.WindowSize.initial_increment;
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

let _update_last_peer_stream ?(strict = false) t stream_id =
  {
    t with
    last_peer_stream =
      (if strict then stream_id else Int32.max stream_id t.last_peer_stream);
  }

let _update_last_local_stream id t =
  { t with last_local_stream = Int32.max id t.last_local_stream }

(*let _update_stream_flow t stream_id new_flow =
  let map =
    StreamMap.update stream_id
      (function
        | None -> None
        | Some (old : _ Stream.t) -> Some { old with flow = new_flow })
      t.map
  in

  { t with map }*)

(*let _update_flow_on_data ~send_update id n t =
  let map =
    StreamMap.update id
      (function
        | None -> None
        | Some o ->
            Some
              {
                o with
                Stream.flow =
                  Flow_control.receive_data ~send_update o.Stream.flow n;
              })
      t.map
  in

  { t with map }*)

(*let _flow_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> Flow_control.initial
  | Some stream -> stream.flow*)
