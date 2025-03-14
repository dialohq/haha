open State

type state = State.t

type request_handler =
  Request.t -> Streams.Stream.(stream_reader * response_writer)

let connection_handler (request_handler : request_handler) socket addr =
  let open Serialize in
  (match addr with
  | `Unix s -> Printf.printf "Starting connection for %s\n%!" s
  | `Tcp (ip, port) ->
      Format.printf "Starting connection for %a:%i@." Eio.Net.Ipaddr.pp ip port);

  let write_condition = Eio.Condition.create () in

  let wakeup_writer () = Eio.Condition.broadcast write_condition in
  let wait_for_write () = Eio.Condition.await_no_mutex write_condition in

  let message_handler (message : Message.t) (state : state) : state option =
    let handle_connection_error () = Obj.magic () in
    match state.phase with
    | Preface preface_state -> (
        match (preface_state.magic_received, message) with
        | false, Magic_string ->
            Some
              {
                state with
                phase = Preface { preface_state with magic_received = true };
              }
        | true, Frame { Frame.frame_payload = Settings settings_list; _ } ->
            write_settings state.faraday Settings.default;
            write_settings_ack state.faraday;
            write_window_update state.faraday Stream_identifier.connection
              Flow_control.WindowSize.initial_increment;
            wakeup_writer ();

            (* this should be taken from the API *)
            let desired_user_settings = Settings.default in

            let frames_state =
              initial_frame_state settings_list desired_user_settings
            in
            Some { state with phase = Frames frames_state }
        | _ -> handle_connection_error ())
    | Frames frames_state -> (
        let next_step next_state =
          Some { state with phase = Frames next_state }
        in

        let connection_error _error_code _msg =
          (* TODO: handle connection error *)
          Some { state with phase = Frames frames_state }
        in
        let stream_error _stream_id _code =
          (* TODO: handler stream error here *)
          Some { state with phase = Frames frames_state }
        in

        match message with
        | Magic_string -> next_step frames_state
        | Frame
            {
              Frame.frame_payload = Data payload;
              frame_header = { flags; stream_id; _ };
              _;
            } -> (
            let end_stream = Flags.test_end_stream flags in
            match Streams.state_of_id frames_state.streams stream_id with
            | Idle | Half_closed (Remote _) ->
                stream_error stream_id Error_code.StreamClosed
            | Reserved _ ->
                connection_error Error_code.ProtocolError
                  "DATA frame received on reserved stream"
            | Closed ->
                connection_error Error_code.StreamClosed
                  "DATA frame received on closed stream!"
            | Open (reader, writers) ->
                reader (Cstruct.of_bigarray payload);
                if end_stream then
                  next_step
                    {
                      frames_state with
                      streams =
                        Streams.stream_transition frames_state.streams stream_id
                          (Half_closed (Remote writers));
                    }
                else
                  next_step
                    {
                      frames_state with
                      streams =
                        Streams.update_last_stream frames_state.streams
                          stream_id;
                    }
            | Half_closed (Local reader) ->
                reader (Cstruct.of_bigarray payload);
                if end_stream then
                  next_step
                    {
                      frames_state with
                      streams =
                        Streams.stream_transition frames_state.streams stream_id
                          Closed;
                    }
                else
                  next_step
                    {
                      frames_state with
                      streams =
                        Streams.update_last_stream frames_state.streams
                          stream_id;
                    })
        | Frame
            { frame_payload = Settings settings_l; frame_header = { flags; _ } }
          -> (
            let is_ack = Flags.test_ack flags in

            match (frames_state.settings_status, is_ack) with
            | _, false ->
                let new_state =
                  {
                    frames_state with
                    peer_settings =
                      Settings.update_with_list frames_state.peer_settings
                        settings_l;
                  }
                in
                (* write_settings f Settings.default ~ack:true (); *)
                (* wakeup_writer (); *)
                next_step new_state
            | Syncing new_settings, true ->
                let new_state =
                  {
                    frames_state with
                    local_settings =
                      Settings.(
                        update_with_list frames_state.local_settings
                          (to_settings_list new_settings));
                    settings_status = Idle;
                  }
                in
                next_step new_state
            | Idle, true ->
                connection_error Error_code.ProtocolError
                  "Unexpected ACK flag in SETTINGS frame.")
        | Frame { frame_payload = Ping bs; _ } ->
            write_ping state.faraday bs ~ack:true;
            wakeup_writer ();
            next_step frames_state
        | Frame
            {
              frame_payload = Headers headers_result;
              frame_header = { flags; stream_id; _ };
              _;
            } -> (
            if frames_state.shutdown then
              connection_error Error_code.ProtocolError
                "client tried to open a stream after sending GOAWAY"
            else if Flags.test_priority flags then
              connection_error Error_code.InternalError
                "Priority not yet implemented"
            else if not (Flags.test_end_header flags) then
              (* TODO: Save HEADERS payload as "in progress" and wait for CONTINUATION, no other frame from ANY stream should be received in this "in progress" state *)
              next_step frames_state
            else
              match headers_result with
              | Error msg ->
                  connection_error Error_code.CompressionError
                    (Format.sprintf "Parsing error: %s" msg)
              | Ok header_list -> (
                  let end_stream = Flags.test_end_stream flags in
                  let pseudo_validation =
                    Headers.Pseudo.validate_request header_list
                  in

                  let stream_state =
                    Streams.state_of_id frames_state.streams stream_id
                  in

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
                                Streams.stream_transition frames_state.streams
                                  stream_id (Half_closed (Remote writers));
                            }
                      | Half_closed (Local _) ->
                          next_step
                            {
                              frames_state with
                              streams =
                                Streams.stream_transition frames_state.streams
                                  stream_id Closed;
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
                              headers = [];
                            }
                          in

                          let reader, response_writer =
                            request_handler request
                          in

                          next_step
                            {
                              frames_state with
                              streams =
                                Streams.stream_transition frames_state.streams
                                  stream_id
                                  (if end_stream then
                                     Half_closed
                                       (Remote
                                          (AwaitingResponse response_writer))
                                   else
                                     Open
                                       (reader, AwaitingResponse response_writer));
                            }
                      | Open _ | Half_closed (Local _) ->
                          stream_error stream_id Error_code.ProtocolError
                      | Reserved _ ->
                          connection_error Error_code.ProtocolError
                            "HEADERS received on reserved stream"
                      | Half_closed (Remote _) | Closed ->
                          connection_error Error_code.StreamClosed
                            "HEADERS received on closed stream")))
        | Frame { frame_payload = Continuation _; _ } ->
            failwith "CONTINUATION not yet implemented"
        | Frame
            { frame_payload = RSTStream _; frame_header = { stream_id; _ }; _ }
          -> (
            match Streams.state_of_id frames_state.streams stream_id with
            | Idle ->
                connection_error Error_code.ProtocolError
                  "RST_STREAM received on a idle stream"
            | Closed ->
                connection_error Error_code.StreamClosed
                  "RST_STREAM received on a closed stream!"
            | _ ->
                (* TODO: check the error code and possibly pass it to API for error handling *)
                next_step
                  {
                    frames_state with
                    streams =
                      Streams.stream_transition frames_state.streams stream_id
                        Closed;
                  })
        | Frame { frame_payload = PushPromise _; _ } ->
            connection_error Error_code.ProtocolError "client cannot push"
        | Frame { frame_payload = GoAway (last_stream_id, code, _msg); _ } -> (
            match code with
            | Error_code.NoError ->
                (* graceful shutdown *)
                (* TODO: when in the graceful shutdown state, we should check if all of the streams below last_stream_id are finished on each intent of closing a stream, meaning 
                     - each time RST_STREAM frame or END_HEADERS flag is sent or recieved, check if all streams left are closed, 
                     if yes, send server's GOAWAY *)
                let new_state =
                  {
                    frames_state with
                    shutdown = true;
                    streams =
                      Streams.update_last_stream ~strict:true
                        frames_state.streams last_stream_id;
                  }
                in
                next_step new_state
            | _ ->
                (* immediately shutdown the connection as the TCP connection should be closed by the client *)
                (* TODO: report this error to API to the connection error handler *)
                None)
        | Frame
            {
              frame_payload = WindowUpdate increment;
              frame_header = { stream_id; _ };
            } -> (
            match Streams.state_of_id frames_state.streams stream_id with
            | Open _ | Reserved Local ->
                if Stream_identifier.is_connection stream_id then
                  next_step
                    {
                      frames_state with
                      flow =
                        Flow_control.incr_out_flow frames_state.flow increment;
                    }
                else
                  next_step
                    {
                      frames_state with
                      streams =
                        Streams.incr_stream_out_flow frames_state.streams
                          stream_id increment;
                    }
            | _ ->
                connection_error Error_code.ProtocolError
                  "unexpected WINDOW_UPDATE")
        | Frame { frame_payload = Unknown _; _ } -> next_step frames_state
        | Frame { frame_payload = Priority _; _ } -> next_step frames_state)
  in

  let read_io (state : state) (cs : Cstruct.t) : int * state option =
    let consumed, frames, new_parse_state =
      Parse.read cs state.parse_state state.hpack_decoder
    in

    let state_with_parse = { state with parse_state = new_parse_state } in

    let next_state =
      List.fold_left
        (fun state frame ->
          match state with
          | None -> None
          | Some state -> message_handler frame state)
        (Some state_with_parse) frames
    in

    (consumed, next_state)
  in

  let initial_state =
    {
      phase = Preface initial_preface_state;
      parse_state = Magic;
      faraday = Faraday.create Settings.default.max_frame_size;
      hpack_decoder = Hpack.Decoder.create 1000;
      hpack_encoder = Hpack.Encoder.create 1000;
    }
  in

  let default_max_frame = Settings.default.max_frame_size in
  Runloop.start ~max_frame_size:default_max_frame ~initial_state ~read_io
    ~wait_for_write socket
