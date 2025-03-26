open Serialize
open Types

let handle_connection_error state error_code msg =
  Printf.printf "Connetion error: %s\n%!" msg;
  let last_stream =
    match state.State.phase with
    | Preface _ -> Int32.zero
    | Frames frames -> frames.streams.last_client_stream
  in
  let debug_data = Bigstringaf.of_string ~off:0 ~len:(String.length msg) msg in
  write_goaway state.faraday last_stream error_code debug_data;
  None

let handle_stream_error state stream_id code =
  write_rst_stream state.State.faraday stream_id code;
  match state.phase with
  | Frames frames_state ->
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
  | _ -> None

let body_writer_handler state (frames_state : ('a, 'b) State.frames_state)
    (f : Types.body_writer) id =
  let stream_flow = Streams.flow_of_id frames_state.streams id in
  match f ~window_size:stream_flow.out_flow with
  | `Data { Cstruct.buffer; off; len } -> (
      match
        Flow_control.incr_sent stream_flow (Int32.of_int len)
          ~initial_window_size:frames_state.peer_settings.initial_window_size
      with
      | Error _ -> failwith "window overflow 1, report to user"
      | Ok new_flow ->
          Serialize.write_data ~end_stream:false state.State.faraday buffer ~off
            ~len id;
          let new_frames_state =
            {
              frames_state with
              streams =
                Streams.update_stream_flow frames_state.streams id new_flow;
            }
          in
          { state with phase = Frames new_frames_state })
  | `End (Some { Cstruct.buffer; off; len }, trailers) -> (
      let send_trailers = List.length trailers > 0 in
      match
        Flow_control.incr_sent stream_flow (Int32.of_int len)
          ~initial_window_size:frames_state.peer_settings.initial_window_size
      with
      | Error _ -> failwith "window overflow 2, report to user"
      | Ok new_flow ->
          Serialize.write_data ~end_stream:(not send_trailers) state.faraday
            buffer ~off ~len id;
          if send_trailers then
            Serialize.write_trailers state.faraday frames_state.hpack_encoder id
              trailers;
          let updated_streams =
            Streams.update_stream_flow frames_state.streams id new_flow
          in
          let new_frames_state =
            match Streams.state_of_id updated_streams id with
            | Open (stream_reader, _) ->
                {
                  frames_state with
                  streams =
                    Streams.stream_transition updated_streams id
                      (Half_closed (Local stream_reader));
                }
            | _ ->
                {
                  frames_state with
                  streams = Streams.stream_transition updated_streams id Closed;
                }
          in
          { state with phase = Frames new_frames_state })
  | `End (None, trailers) ->
      let send_trailers = List.length trailers > 0 in
      if send_trailers then
        Serialize.write_trailers state.faraday frames_state.hpack_encoder id
          trailers
      else
        Serialize.write_data ~end_stream:true state.faraday Bigstringaf.empty
          ~off:0 ~len:0 id;
      let new_frames_state =
        match Streams.state_of_id frames_state.streams id with
        | Open (stream_reader, _) ->
            {
              frames_state with
              streams =
                Streams.stream_transition frames_state.streams id
                  (Half_closed (Local stream_reader));
            }
        | _ ->
            {
              frames_state with
              streams = Streams.stream_transition frames_state.streams id Closed;
            }
      in
      { state with phase = Frames new_frames_state }
  | `Yield -> Eio.Fiber.await_cancel ()

let token_handler ~process_complete_headers ~process_data_frame ~handle_preface
    ~error_handler ~peer (token : token) state =
  match state.State.phase with
  | Preface magic_received -> (
      match (magic_received, token) with
      | false, Magic_string -> Some { state with phase = Preface true }
      | true, Frame { Frame.frame_payload = Settings settings_list; _ } ->
          handle_preface state settings_list
      | _ ->
          handle_connection_error state Error_code.ProtocolError
            "Incorrect client connection preface")
  | Frames frames_state -> (
      let no_error_close () =
        write_goaway state.faraday frames_state.streams.last_server_stream
          Error_code.NoError Bigstringaf.empty;

        None
      in
      let connection_error = handle_connection_error state in
      let stream_error = handle_stream_error state in
      let next_step next_state =
        Some { state with phase = Frames next_state }
      in

      let process_complete_headers =
        process_complete_headers frames_state stream_error connection_error
          next_step
      in
      let process_data_frame =
        process_data_frame frames_state stream_error connection_error next_step
          no_error_close
      in
      let decompress_headers_block bs ~len hpack_decoder =
        let hpack_parser = Hpackv.Decoder.decode_headers hpack_decoder in
        let error' ?msg () =
          Error
            (match msg with
            | None -> "Decompression error"
            | Some msg -> Format.sprintf "Decompression error: %s" msg)
        in
        match Angstrom.Unbuffered.parse hpack_parser with
        | Fail (_, _, msg) -> error' ~msg ()
        | Done _ -> error' ()
        | Partial { continue; _ } -> (
            match continue bs ~off:0 ~len Complete with
            | Partial _ -> error' ()
            | Fail (_, _, msg) -> error' ~msg ()
            | Done (_, result') ->
                Result.map_error
                  (fun _ -> "Decompression error, hpack error")
                  result'
                |> Result.map Headers.of_hpack_list)
      in

      let process_headers_frame frame_header bs =
        let { Frame.flags; stream_id; _ } = frame_header in
        if frames_state.shutdown then
          connection_error Error_code.ProtocolError
            "client tried to open a stream after sending GOAWAY"
        else if
          stream_id
          <
          match peer with
          | `Server -> frames_state.streams.last_client_stream
          | `Client -> frames_state.streams.last_server_stream
        then
          connection_error Error_code.ProtocolError
            "received HEADERS with stream ID smaller than the last client open \
             stream"
        else if not (Flags.test_end_header flags) then (
          let headers_buffer = Bigstringaf.create 10000 in
          let len = Bigstringaf.length bs in
          Bigstringaf.blit bs ~src_off:0 headers_buffer ~dst_off:0 ~len;

          next_step
            {
              frames_state with
              headers_state = InProgress (headers_buffer, len);
            })
        else
          match
            decompress_headers_block bs ~len:(Bigstringaf.length bs)
              frames_state.hpack_decoder
          with
          | Error msg -> connection_error Error_code.CompressionError msg
          | Ok headers -> process_complete_headers frame_header headers
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

      let process_settings_frame flags settings_list =
        let is_ack = Flags.test_ack flags in

        match (frames_state.settings_status, is_ack) with
        | _, false -> (
            let new_state =
              {
                frames_state with
                peer_settings =
                  Settings.update_with_list frames_state.peer_settings
                    settings_list;
              }
            in

            match State.update_hpack_capacity new_state with
            | Error _ ->
                connection_error Error_code.ProtocolError
                  "Error updating Hpack buffer capacity"
            | Ok _ ->
                write_settings_ack state.faraday;
                next_step new_state)
        | Syncing new_settings, true -> (
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

            match State.update_hpack_capacity new_state with
            | Error _ ->
                connection_error Error_code.ProtocolError
                  "Error updating Hpack buffer capacity"
            | Ok _ -> next_step new_state)
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
                    Streams.incr_stream_out_flow frames_state.streams stream_id
                      increment;
                }
          | _ ->
              Printf.printf "unexpected WINDOW_UPDATE, stream_id %li\n%!"
                stream_id;
              connection_error Error_code.ProtocolError
                "unexpected WINDOW_UPDATE"
      in

      match (frames_state.headers_state, token) with
      | InProgress _, Frame { Frame.frame_payload = Continuation _; _ }
      | Idle, _ -> (
          match token with
          | Magic_string -> next_step frames_state
          | Frame
              {
                Frame.frame_payload = Data payload;
                frame_header = { flags; stream_id; _ };
                _;
              } ->
              process_data_frame flags stream_id payload
          | Frame
              { frame_payload = Settings payload; frame_header = { flags; _ } }
            ->
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
      | InProgress _, _ ->
          connection_error Error_code.ProtocolError
            "unexpected frame other than CONTINUATION in the middle of headers \
             block")
