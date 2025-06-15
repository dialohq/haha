open Runtime

type iter_input = Shutdown | Request of Request.t
type state = Streams.client_peer State.t
type iteration = iter_input Types.iteration
type stream_state = Streams.client_peer Streams.Stream.t

(*
let process_response :
    state ->
    Header.Pseudo.response_pseudo ->
    bool ->
    Header.t list ->
    stream_state ->
    Stream_identifier.t ->
    state step =
 fun state pseudo end_stream header_list (State stream_state) stream_id ->
  let connection_error = step_connection_error state in
  let headers = Header.filter_pseudo header_list in
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
  match (stream_state, is_final) with
  | ( Open
        ({ readers = AwaitingResponse response_handler; context; _ } as state'),
      false ) ->
      let _body_reader, context = response_handler context @@ response () in

      let streams =
        Streams.stream_transition state.streams stream_id
          (State (Open { state' with context }))
      in

      step InProgress { state with streams }
  | ( HalfClosed
        (Local
           ({ readers = AwaitingResponse response_handler; context; _ } as
            state')),
      false ) ->
      let _body_reader, context = response_handler context @@ response () in

      let streams =
        Streams.stream_transition state.streams stream_id
          (State (HalfClosed (Local { state' with context })))
      in

      step InProgress { state with streams }
  | ( Open
        {
          readers = AwaitingResponse response_handler;
          writers = body_writer;
          error_handler;
          on_close;
          context;
        },
      true ) ->
      let body_reader, context = response_handler context @@ response () in

      let new_stream_state : stream_state =
        match (body_reader, end_stream) with
        | None, _ ->
            Writer.write_rst_stream state.writer stream_id NoError;
            on_close context;
            State Closed
        | Some _, true ->
            State
              (HalfClosed
                 (Remote
                    { writers = body_writer; error_handler; on_close; context }))
        | Some body_reader, false ->
            State
              (Open
                 {
                   readers = BodyReader body_reader;
                   writers = body_writer;
                   error_handler;
                   on_close;
                   context;
                 })
      in

      step InProgress
        {
          state with
          streams =
            Streams.stream_transition state.streams stream_id new_stream_state;
        }
  | ( HalfClosed
        (Local
           {
             readers = AwaitingResponse response_handler;
             error_handler;
             context;
             on_close;
           }),
      true ) ->
      let body_reader, context = response_handler context @@ response () in

      let new_stream_state : stream_state =
        match (end_stream, body_reader) with
        | false, None ->
            Writer.write_rst_stream state.writer stream_id NoError;
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
                    }))
        | true, _ ->
            on_close context;
            State Closed
      in
      let streams =
        Streams.stream_transition state.streams stream_id new_stream_state
      in
      step InProgress { state with streams }
  | Open { readers = BodyReader _; _ }, _
  | HalfClosed (Local { readers = BodyReader _; _ }), _ ->
      connection_error Error_code.ProtocolError
        (Format.sprintf
           "unexpected multiple non-informational HEADERS on stream %li"
           stream_id)
  | Idle, _ ->
      connection_error Error_code.ProtocolError
        "unexpected HEADERS response on idle stream"
  | Reserved _, _ ->
      connection_error Error_code.ProtocolError
        "HEADERS received on reserved stream"
  | HalfClosed (Remote _), _ | Closed, _ ->
      connection_error Error_code.StreamClosed
        "HEADERS received on closed stream"
*)

let process_complete_headers :
    state -> Frame.frame_header -> Header.t list -> state step =
 fun state { Frame.flags; stream_id; _ } headers ->
  let stream_error = step_stream_error state in
  let pseudo_validation = Header.Pseudo.validate_response headers in

  match (Flags.test_end_stream flags, pseudo_validation) with
  | _, Invalid | false, No_pseudo ->
      stream_error stream_id Error_code.ProtocolError
  | true, No_pseudo -> (
      match Streams.receive_trailers ~headers stream_id state.streams with
      | Error err -> step (ConnectionError err) state
      | Ok streams -> step InProgress { state with streams })
  | end_stream, Valid pseudo -> (
      match
        Streams.receive_response ~pseudo ~end_stream ~headers
          ~writer:state.writer stream_id state.streams
      with
      | Error err -> step (ConnectionError err) state
      | Ok streams -> step InProgress { state with streams })

let input_handler : state -> iter_input -> state =
 fun ({ shutdown; writer; streams; _ } as state) input ->
  if shutdown then
    invalid_arg "HTTP/2 iteration: cannot pass inputs after Shutdown";
  match input with
  | Shutdown ->
      Writer.write_goaway writer
        (Streams.last_peer_stream streams)
        Error_code.NoError;
      let new_state = { state with shutdown = true } in
      new_state
  | Request request ->
      { state with streams = Streams.write_request ~writer ~request streams }

let connect : 'c. ?config:Settings.t -> _ Eio.Resource.t -> iteration =
 fun ?(config = Settings.default) socket ->
  let frame_handler = frame_handler ~process_complete_headers in

  let initial_writer =
    Writer.create ~header_table_size:Settings.default.header_table_size
      Settings.default.max_frame_size
  in
  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in

  Writer.write_connection_preface initial_writer;
  Writer.write_settings initial_writer user_settings;

  let initial_state_result =
    match Writer.write initial_writer socket with
    | Ok () -> (
        match process_preface_settings ~socket ~receive_buffer () with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial_client ~user_settings ~peer_settings ~writer,
                rest_to_parse ))
    | Error exn -> Error (Exn exn)
  in

  start ~frame_handler ~receive_buffer ~initial_state_result ~input_handler
    socket
