type state = Streams.((client_readers, client_writer) State.t)
type frames_state = Streams.((client_readers, client_writer) State.frames_state)
type stream_state = Streams.((client_readers, client_writer) Stream.state)

let run ~(error_handler : Error.t -> unit)
    ~(request_writer : Request.request_writer) (config : Settings.t) socket =
  let open Serialize in
  let preinitial_state = State.initial () in

  write_connection_preface preinitial_state.faraday;
  write_settings preinitial_state.faraday config;

  (match Faraday.operation preinitial_state.faraday with
  | `Close | `Yield -> ()
  | `Writev bs_list ->
      let written, cs_list =
        List.fold_left
          (fun ((to_write, cs_list) : int * Cstruct.t list)
               (bs_iovec : Bigstringaf.t Faraday.iovec) ->
            ( bs_iovec.len + to_write,
              Cstruct.of_bigarray ~off:bs_iovec.off ~len:bs_iovec.len
                bs_iovec.buffer
              :: cs_list ))
          (0, []) bs_list
      in
      Eio.Flow.write socket (List.rev cs_list);
      Faraday.shift preinitial_state.faraday written);

  let handle_preface (state : state) (recvd_settings : Settings.settings_list) :
      state option =
    write_settings_ack state.faraday;
    write_window_update state.faraday Stream_identifier.connection
      Flow_control.WindowSize.initial_increment;
    let frames_state = State.initial_frame_state recvd_settings config in

    Some { state with phase = Frames frames_state }
  in

  let process_data_frame (frames_state : frames_state) stream_error
      connection_error next_step no_error_close flags stream_id bs :
      state option =
    let end_stream = Flags.test_end_stream flags in
    match (Streams.state_of_id frames_state.streams stream_id, end_stream) with
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
            frames_state with
            streams =
              Streams.stream_transition frames_state.streams stream_id
                (Half_closed (Remote writers));
          }
    | Open (BodyStream reader, _), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            frames_state with
            streams = Streams.update_last_stream frames_state.streams stream_id;
          }
    | Half_closed (Local (BodyStream reader)), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        let new_streams =
          Streams.stream_transition frames_state.streams stream_id Closed
        in

        if
          frames_state.shutdown
          && Streams.all_closed
               ~last_stream_id:frames_state.streams.last_client_stream
               new_streams
        then no_error_close ()
        else next_step { frames_state with streams = new_streams }
    | Half_closed (Local (BodyStream reader)), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            frames_state with
            streams = Streams.update_last_stream frames_state.streams stream_id;
          }
  in

  let process_complete_headers (frames_state : frames_state) stream_error
      connection_error next_step { Frame.flags; stream_id; _ } header_list =
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Headers.Pseudo.validate_response header_list in

    let stream_state = Streams.state_of_id frames_state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        Printf.printf "Received some HEADERS, trailers\n%!";
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
        (* TODO: should expose trailers to API - body_reader could take some `Data of cs and `End of data option * trailers variants *)
        match stream_state with
        | Open (_, writers) ->
            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    (Half_closed (Remote writers));
              }
        | Half_closed (Local _) ->
            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    Closed;
              }
        | Reserved _ ->
            (* TODO: check if this is the correct error *)
            stream_error stream_id Error_code.ProtocolError
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

            next_step frames_state
        | Open (AwaitingResponse response_handler, body_writer), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then Half_closed (Remote body_writer)
              else Open (BodyStream body_reader, body_writer)
            in

            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
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
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
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

  let token_handler =
    Runtime.token_handler ~process_complete_headers ~process_data_frame
      ~handle_preface ~error_handler ~peer:`Client
  in

  let request_writer_handler state frames_state =
    let request = request_writer () in

    let id = Streams.get_next_id frames_state.State.streams `Client in
    writer_request_headers state.State.faraday frames_state.hpack_encoder id
      request;
    write_window_update state.faraday id
      Flow_control.WindowSize.initial_increment;
    let response_handler = Option.get request.response_handler in
    let stream_state : stream_state =
      match request.body_writer with
      | Some body_writer ->
          Streams.Stream.Open (AwaitingResponse response_handler, body_writer)
      | None -> Half_closed (Local (AwaitingResponse response_handler))
    in
    let new_frames_state =
      {
        frames_state with
        streams = Streams.stream_transition frames_state.streams id stream_state;
      }
    in
    { state with phase = Frames new_frames_state }
  in

  let get_body_writers frames_state =
    Streams.body_writers (`Client frames_state.State.streams)
  in

  let initial_state =
    { preinitial_state with phase = Preface true; parse_state = Frames None }
  in
  let default_max_frame_size = Settings.default.max_frame_size in
  Runloop.start ~request_writer_handler ~token_handler
    ~max_frame_size:default_max_frame_size ~get_body_writers ~initial_state 0
    socket
