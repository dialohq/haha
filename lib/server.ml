open State

type state = State.t

type request_handler =
  Request.t -> Streams.Stream.(stream_reader * response_writer)

(* TODO: config argument could have some more user-friendly type so there is no need to look into RFC *)
let connection_handler ~(error_handler : Error.t -> unit)
    ?(goaway_writer : (unit -> unit) option) (config : Settings.t)
    (request_handler : request_handler) socket addr =
  let open Serialize in
  (match addr with
  | `Unix s -> Printf.printf "Starting connection for %s\n%!" s
  | `Tcp (ip, port) ->
      Format.printf "Starting connection for %a:%i@." Eio.Net.Ipaddr.pp ip port);

  let message_handler (message : Message.t) (state : state) : state option =
    let handle_connection_error error_code msg =
      Printf.printf "Connetion error: %s\n%!" msg;
      let last_stream =
        match state.phase with
        | Preface _ -> Int32.zero
        | Frames frames -> frames.streams.last_client_stream
      in
      let debug_data =
        Bigstringaf.of_string ~off:0 ~len:(String.length msg) msg
      in
      write_goaway state.faraday last_stream error_code debug_data;
      None
    in
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

            let desired_user_settings = config in

            let frames_state =
              initial_frame_state settings_list desired_user_settings
            in
            Some { state with phase = Frames frames_state }
        | _ ->
            handle_connection_error Error_code.ProtocolError
              "Incorrect client connection preface")
    | Frames frames_state -> (
        let next_step next_state =
          Some { state with phase = Frames next_state }
        in

        let connection_error = handle_connection_error in
        let stream_error stream_id code =
          write_rst_stream state.faraday stream_id code;
          Some
            {
              state with
              phase =
                Frames
                  {
                    frames_state with
                    streams =
                      Streams.stream_transition frames_state.streams stream_id
                        Closed;
                  };
            }
        in
        let no_error_close () =
          write_goaway state.faraday frames_state.streams.last_server_stream
            Error_code.NoError Bigstringaf.empty;

          None
        in

        let decompress_headers_block bs ~len hpack_decoder =
          let hpack_parser = Hpack.Decoder.decode_headers hpack_decoder in
          let error' = Error "Decompression error" in
          match Angstrom.Unbuffered.parse hpack_parser with
          | Fail _ -> error'
          | Done _ -> error'
          | Partial { continue; _ } -> (
              match continue bs ~off:0 ~len Complete with
              | Partial _ -> error'
              | Fail _ -> error'
              | Done (_, result') ->
                  Result.map_error (fun _ -> "Decompression error") result'
                  |> Result.map Headers.of_hpack_list)
        in

        let process_complete_headers { Frame.flags; stream_id; _ } header_list =
          let end_stream = Flags.test_end_stream flags in
          let pseudo_validation = Headers.Pseudo.validate_request header_list in

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
                      headers = [];
                      stream_id;
                    }
                  in

                  let reader, response_writer = request_handler request in
                  Printf.printf "Starting a new stream with ID: %li\n%!"
                    stream_id;

                  next_step
                    {
                      frames_state with
                      streams =
                        Streams.stream_transition frames_state.streams stream_id
                          (if end_stream then
                             Half_closed
                               (Remote (AwaitingResponse response_writer))
                           else Open (reader, AwaitingResponse response_writer));
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

        let process_headers_frame frame_header bs =
          let { Frame.flags; payload_length; _ } = frame_header in
          if frames_state.shutdown then
            connection_error Error_code.ProtocolError
              "client tried to open a stream after sending GOAWAY"
          else if Flags.test_priority flags then
            connection_error Error_code.InternalError "Priority not implemented"
          else if not (Flags.test_end_header flags) then (
            let headers_buffer = Bigstringaf.create 10000 in
            let len = Bigstringaf.length bs in
            Bigstringaf.blit bs ~src_off:0 headers_buffer ~dst_off:0 ~len;

            next_step
              {
                frames_state with
                headers_state = InProgress (headers_buffer, len);
              })
          else (
            Printf.printf "Bs len: %i | payload_length: %i\n%!"
              (Bigstringaf.length bs) payload_length;
            match
              decompress_headers_block bs ~len:(Bigstringaf.length bs)
                frames_state.hpack_decoder
            with
            | Error msg -> connection_error Error_code.CompressionError msg
            | Ok headers -> process_complete_headers frame_header headers)
        in

        let process_continuation_frame frame_header bs =
          let { Frame.flags; _ } = frame_header in
          match frames_state.headers_state with
          | Idle ->
              connection_error Error_code.InternalError
                "unexpected CONTINUATION frame"
          | InProgress (buffer, len) -> (
              let new_buffer, new_len =
                try
                  Bigstringaf.blit bs ~src_off:0 buffer ~dst_off:len
                    ~len:(Bigstringaf.length bs);
                  (buffer, len + Bigstringaf.length bs)
                with Invalid_argument _ ->
                  let new_buff =
                    Bigstringaf.create
                      ((Bigstringaf.length buffer + Bigstringaf.length bs) * 2)
                  in
                  Bigstringaf.blit buffer ~src_off:0 new_buff ~dst_off:0 ~len;
                  Bigstringaf.blit bs ~src_off:0 new_buff ~dst_off:len
                    ~len:(Bigstringaf.length bs);
                  (new_buff, len + Bigstringaf.length bs)
              in

              if not (Flags.test_end_header flags) then
                next_step
                  {
                    frames_state with
                    headers_state = InProgress (new_buffer, new_len);
                  }
              else
                match
                  decompress_headers_block new_buffer ~len:new_len
                    frames_state.hpack_decoder
                with
                | Error msg -> connection_error Error_code.CompressionError msg
                | Ok headers -> process_complete_headers frame_header headers)
        in

        let process_data_frame flags stream_id bs =
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
              reader (Cstruct.of_bigarray bs);
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
                      Streams.update_last_stream frames_state.streams stream_id;
                  }
          | Half_closed (Local reader) ->
              reader (Cstruct.of_bigarray bs);
              if end_stream then
                let new_streams =
                  Streams.stream_transition frames_state.streams stream_id
                    Closed
                in

                if
                  frames_state.shutdown
                  && Streams.all_closed
                       ~last_stream_id:frames_state.streams.last_client_stream
                       new_streams
                then no_error_close ()
                else next_step { frames_state with streams = new_streams }
              else
                next_step
                  {
                    frames_state with
                    streams =
                      Streams.update_last_stream frames_state.streams stream_id;
                  }
        in

        let process_settings_frame flags settings_list =
          let is_ack = Flags.test_ack flags in

          match (frames_state.settings_status, is_ack) with
          | _, false ->
              let new_state =
                {
                  frames_state with
                  peer_settings =
                    Settings.update_with_list frames_state.peer_settings
                      settings_list;
                }
              in
              write_settings_ack state.faraday;
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
                "Unexpected ACK flag in SETTINGS frame."
        in

        let process_rst_stream_frame stream_id error_code =
          match Streams.state_of_id frames_state.streams stream_id with
          | Idle ->
              connection_error Error_code.ProtocolError
                "RST_STREAM received on a idle stream"
          | Closed ->
              connection_error Error_code.StreamClosed
                "RST_STREAM received on a closed stream!"
          | _ -> (
              error_handler (Error.StreamError (stream_id, error_code));
              let new_streams =
                Streams.stream_transition frames_state.streams stream_id Closed
              in
              match
                ( frames_state.shutdown,
                  Streams.all_closed
                    ~last_stream_id:frames_state.streams.last_client_stream
                    new_streams )
              with
              | true, true -> no_error_close ()
              | _ -> next_step { frames_state with streams = new_streams })
        in

        let process_goaway_frame payload =
          let last_stream_id, code, msg = payload in
          match code with
          | Error_code.NoError -> (
              (* graceful shutdown *)
              match Streams.all_closed ~last_stream_id frames_state.streams with
              | false ->
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
              | true -> no_error_close ())
          | _ ->
              error_handler
                (Error.ConnectionError (code, Bigstringaf.to_string msg));
              None
        in

        let process_window_update_frame stream_id increment =
          if Stream_identifier.is_connection stream_id then
            next_step
              {
                frames_state with
                flow = Flow_control.incr_out_flow frames_state.flow increment;
              }
          else
            match Streams.state_of_id frames_state.streams stream_id with
            | Open _ | Reserved Local | Half_closed _ ->
                next_step
                  {
                    frames_state with
                    streams =
                      Streams.incr_stream_out_flow frames_state.streams
                        stream_id increment;
                  }
            | _ ->
                connection_error Error_code.ProtocolError
                  "unexpected WINDOW_UPDATE"
        in

        match message with
        | Magic_string -> next_step frames_state
        | Frame
            {
              Frame.frame_payload = Data payload;
              frame_header = { flags; stream_id; _ };
              _;
            } ->
            process_data_frame flags stream_id payload
        | Frame
            { frame_payload = Settings payload; frame_header = { flags; _ } } ->
            process_settings_frame flags payload
        | Frame { frame_payload = Ping bs; _ } ->
            write_ping state.faraday bs ~ack:true;
            next_step frames_state
        | Frame { frame_payload = Headers payload; frame_header; _ } ->
            process_headers_frame frame_header payload
        | Frame { frame_payload = Continuation payload; frame_header; _ } ->
            process_continuation_frame frame_header payload
        | Frame
            {
              frame_payload = RSTStream payload;
              frame_header = { stream_id; _ };
              _;
            } ->
            process_rst_stream_frame stream_id payload
        | Frame { frame_payload = PushPromise _; _ } ->
            connection_error Error_code.ProtocolError "client cannot push"
        | Frame { frame_payload = GoAway payload; _ } ->
            process_goaway_frame payload
        | Frame
            {
              frame_payload = WindowUpdate payload;
              frame_header = { stream_id; _ };
            } ->
            process_window_update_frame stream_id payload
        | Frame { frame_payload = Unknown _; _ } -> next_step frames_state
        | Frame { frame_payload = Priority _; _ } -> next_step frames_state)
  in

  let read_io (state : state) (cs : Cstruct.t) : int * state option =
    let consumed, frames, new_parse_state = Parse.read cs state.parse_state in

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
      hpack_encoder = Hpack.Encoder.create 1000;
    }
  in

  let default_max_frame = Settings.default.max_frame_size in
  Runloop.start ~max_frame_size:default_max_frame ~initial_state ~read_io
    ?await_user_goaway:goaway_writer socket
