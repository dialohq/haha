open Types

type state = Streams.((server_reader, server_writers) State.t)
type frames_state = Streams.((server_reader, server_writers) State.frames_state)
type stream_state = Streams.((server_reader, server_writers) Stream.state)
type request_handler = Request.t -> body_reader * Response.response_writer

(* TODO: config argument could have some more user-friendly type so there is no need to look into RFC *)
let connection_handler ~(error_handler : Error.t -> unit)
    ?(goaway_writer : (unit -> unit) option) (config : Settings.t)
    (request_handler : request_handler) socket addr =
  let port = match addr with `Tcp (_, p) -> p | _ -> -1 in
  let handle_preface state (recvd_settings : Settings.settings_list) :
      ('a, 'b) State.t option =
    let open Serialize in
    write_settings state.State.faraday config;
    write_settings_ack state.faraday;
    write_window_update state.faraday Stream_identifier.connection
      Flow_control.WindowSize.initial_increment;
    let frames_state = State.initial_frame_state recvd_settings config in

    Some { state with phase = Frames frames_state }
  in

  let process_data_frame (frames_state : frames_state) stream_error
      connection_error next_step no_error_close flags stream_id bs =
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
    | Open (reader, writers), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        next_step
          {
            frames_state with
            streams =
              Streams.stream_transition frames_state.streams stream_id
                (Half_closed (Remote writers));
          }
    | Open (reader, _), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            frames_state with
            streams = Streams.update_last_stream frames_state.streams stream_id;
          }
    | Half_closed (Local reader), true ->
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
    | Half_closed (Local reader), false ->
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
    let pseudo_validation = Headers.Pseudo.validate_request header_list in

    let stream_state = Streams.state_of_id frames_state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
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
        match stream_state with
        | Idle ->
            let request =
              {
                Request.meth = Method.of_string pseudo.meth;
                path = pseudo.path;
                authority = pseudo.authority;
                scheme = pseudo.scheme;
                headers = Headers.filter_pseudo header_list;
                body_writer = None;
                response_handler = None;
              }
            in

            let reader, response_writer = request_handler request in

            let new_stream_state : stream_state =
              if end_stream then
                Half_closed (Remote (WritingResponse response_writer))
              else Open (reader, WritingResponse response_writer)
            in

            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    new_stream_state;
              }
        | Open _ | Half_closed (Local _) ->
            stream_error stream_id Error_code.ProtocolError
        | Reserved _ ->
            connection_error Error_code.ProtocolError
              "HEADERS received on reserved stream"
        | Half_closed (Remote _) | Closed ->
            connection_error Error_code.StreamClosed
              "HEADERS received on closed stream")
  in

  let token_handler =
    Runtime.token_handler ~process_complete_headers ~process_data_frame
      ~handle_preface ~error_handler ~peer:`Server
  in

  let response_writer_handler state frames_state response_writer reader_opt id =
    let response = response_writer () in

    Serialize.write_headers_response state.State.faraday
      frames_state.State.hpack_encoder id response;
    match response with
    | `Final { body_writer = Some body_writer; _ } ->
        Serialize.write_window_update state.faraday id
          Flow_control.WindowSize.initial_increment;
        let new_frames_state =
          {
            frames_state with
            streams = Streams.change_writer frames_state.streams id body_writer;
          }
        in
        { state with phase = Frames new_frames_state }
    | `Final { body_writer = None; _ } ->
        Serialize.write_window_update state.faraday id
          Flow_control.WindowSize.initial_increment;
        let new_stream_state =
          match reader_opt with
          | None -> Streams.Stream.Closed
          | Some reader -> Half_closed (Local reader)
        in
        let new_frames_state =
          {
            frames_state with
            streams =
              Streams.stream_transition frames_state.streams id new_stream_state;
          }
        in
        { state with phase = Frames new_frames_state }
    | `Interim _ -> state
  in
  let get_response_writers state frames_state =
    let response_writers =
      Streams.response_writers frames_state.State.streams
    in

    List.map
      (fun (response_writer, reader_opt, id) () ->
        response_writer_handler state frames_state response_writer reader_opt id)
      response_writers
  in
  let get_body_writers frames_state =
    Streams.body_writers (`Server frames_state.State.streams)
  in

  let combine_states fs1 fs2 =
    {
      fs1 with
      State.streams =
        Streams.combine_after_response fs1.State.streams fs2.State.streams;
    }
  in

  let default_max_frame = Settings.default.max_frame_size in
  let initial_state = State.initial () in
  Runloop.start ~max_frame_size:default_max_frame ~token_handler
    ~get_body_writers ~get_response_writers ~combine_states ~initial_state
    ?await_user_goaway:goaway_writer port socket
