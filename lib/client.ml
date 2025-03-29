open Writer

type state = Streams.((client_readers, client_writer) State.state)
type stream_state = Streams.((client_readers, client_writer) Stream.state)

let run ~(error_handler : Error.t -> unit)
    ~(request_writer : Request.request_writer) (config : Settings.t) socket =
  let process_data_frame (state : state) stream_error connection_error next_step
      no_error_close { Frame.flags; stream_id; _ } bs =
    let end_stream = Flags.test_end_stream flags in
    match (Streams.state_of_id state.streams stream_id, end_stream) with
    | Idle, _ | Half_closed (Remote _), _ ->
        stream_error stream_id Error_code.StreamClosed
    | Reserved _, _ ->
        connection_error Error_code.ProtocolError
          "DATA frame received on reserved stream"
    | Closed, _ ->
        connection_error Error_code.StreamClosed
          "DATA frame received on closed stream!"
    | Open (AwaitingResponse _, _), _
    | Half_closed (Local (AwaitingResponse _)), _ ->
        stream_error stream_id Error_code.ProtocolError
    | Open (BodyStream reader, writers), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        next_step
          {
            state with
            streams =
              Streams.stream_transition state.streams stream_id
                (Half_closed (Remote writers));
          }
    | Open (BodyStream reader, _), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            state with
            streams = Streams.update_last_stream state.streams stream_id;
          }
    | Half_closed (Local (BodyStream reader)), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        let new_streams =
          Streams.stream_transition state.streams stream_id Closed
        in

        if
          state.shutdown
          && Streams.all_closed ~last_stream_id:state.streams.last_client_stream
               new_streams
        then no_error_close ()
        else next_step { state with streams = new_streams }
    | Half_closed (Local (BodyStream reader)), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            state with
            streams = Streams.update_last_stream state.streams stream_id;
          }
  in

  let process_complete_headers (state : state) stream_error connection_error
      next_step { Frame.flags; stream_id; _ } header_list =
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Headers.Pseudo.validate_response header_list in

    let stream_state = Streams.state_of_id state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
        match stream_state with
        | Open (BodyStream reader, writers) ->
            reader (`End (None, header_list));
            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    (Half_closed (Remote writers));
              }
        | Half_closed (Local (BodyStream reader)) ->
            reader (`End (None, header_list));
            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id Closed;
              }
        | Open (AwaitingResponse _, _)
        | Half_closed (Local (AwaitingResponse _)) ->
            connection_error Error_code.ProtocolError
              "received first HEADERS in this stream with no pseudo-headers"
        | Reserved _ -> stream_error stream_id Error_code.StreamClosed
        | Idle -> stream_error stream_id Error_code.ProtocolError
        | Closed | Half_closed (Remote _) ->
            connection_error Error_code.StreamClosed
              "HEADERS received on a closed stream")
    | end_stream, Valid pseudo -> (
        let headers = Headers.filter_pseudo header_list in
        let response : Response.t =
          match Status.of_code pseudo.status with
          | #Status.informational as status -> `Interim { status; headers }
          | status -> `Final { status; headers; body_writer = None }
        in
        match (stream_state, response) with
        | Open (AwaitingResponse response_handler, _), `Interim _
        | Half_closed (Local (AwaitingResponse response_handler)), `Interim _ ->
            let _body_reader = response_handler response in

            next_step state
        | Open (AwaitingResponse response_handler, body_writer), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then Half_closed (Remote body_writer)
              else Open (BodyStream body_reader, body_writer)
            in

            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    new_stream_state;
              }
        | Half_closed (Local (AwaitingResponse response_handler)), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then Closed
              else Half_closed (Local (BodyStream body_reader))
            in

            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    new_stream_state;
              }
        | Open (BodyStream _, _), _ | Half_closed (Local (BodyStream _)), _ ->
            connection_error Error_code.ProtocolError
              "unexpected multiple non-informational HEADERS on single stream"
        | Idle, _ ->
            connection_error Error_code.ProtocolError
              "unexpected HEADERS response on idle stream"
        | Reserved _, _ ->
            connection_error Error_code.ProtocolError
              "HEADERS received on reserved stream"
        | Half_closed (Remote _), _ | Closed, _ ->
            connection_error Error_code.StreamClosed
              "HEADERS received on closed stream")
  in

  let frame_handler =
    Runtime.frame_handler ~process_complete_headers ~process_data_frame
      ~error_handler ~peer:`Client
  in

  let request_writer_handler (state : state) =
    let request = request_writer () in

    let id = Streams.get_next_id state.streams `Client in
    writer_request_headers state.writer state.hpack_encoder id request;
    write_window_update state.writer id
      Flow_control.WindowSize.initial_increment;
    let response_handler = Option.get request.response_handler in
    let stream_state : stream_state =
      match request.body_writer with
      | Some body_writer ->
          Streams.Stream.Open (AwaitingResponse response_handler, body_writer)
      | None -> Half_closed (Local (AwaitingResponse response_handler))
    in
    {
      state with
      streams = Streams.stream_transition state.streams id stream_state;
    }
  in

  let get_body_writers frames_state =
    Streams.body_writers (`Client frames_state.State.streams)
  in

  (* TODO: we could create so scoped function here for the initial writer to be sure it is freed *)
  let initial_writer = create Settings.default.max_frame_size in
  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in

  write_connection_preface initial_writer;
  write_settings initial_writer user_settings;

  write initial_writer socket;

  let initial_state_result =
    match Runtime.parse_preface_settings ~socket ~receive_buffer 0 0 0 None with
    | Error _ as err -> err
    | Ok (peer_settings, rest_to_parse, writer) ->
        Ok (State.initial ~user_settings ~peer_settings ~writer, rest_to_parse)
  in

  Runloop.start ~request_writer_handler ~frame_handler ~receive_buffer
    ~get_body_writers ~initial_state_result socket
