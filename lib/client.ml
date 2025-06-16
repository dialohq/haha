open H2kit
open Runtime

type iter_input = Shutdown | Request of Request.t
type state = Streams.client_peer State.t
type iteration = iter_input Types.iteration

let process_complete_headers :
    state -> Frame.frame_header -> Headers.t -> state step =
 fun state { Frame.flags; stream_id; _ } headers ->
  let stream_error = step_stream_error state in
  let pseudo_validation = Headers.Pseudo.validate headers in

  match (Flags.test_end_stream flags, pseudo_validation) with
  | _, Invalid _ | false, NotPresent | _, Valid (Request _) ->
      stream_error stream_id Error_code.ProtocolError
  | true, NotPresent -> (
      match
        Streams.receive_trailers ~writer:state.writer ~headers stream_id
          state.streams
      with
      | Error err -> step (ConnectionError err) state
      | Ok streams -> step InProgress { state with streams })
  | end_stream, Valid (Response pseudo) -> (
      match
        Streams.receive_response ~pseudo ~end_stream
          ~headers:(Headers.filter_out_pseudo headers)
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
