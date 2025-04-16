open Writer

let handle_connection_error ?state ((error_code, msg) : Error.connection_error)
    =
  let last_stream =
    match state with
    | None -> Int32.zero
    (* TODO: change last id to peer stream id, not just client *)
    | Some state -> state.State.streams.last_peer_stream
  in
  let debug_data = Bigstringaf.of_string ~off:0 ~len:(String.length msg) msg in
  match state with
  | Some { writer; _ } -> write_goaway ~debug_data writer last_stream error_code
  | None ->
      let writer = create (9 + 4 + 4 + String.length msg) in
      write_goaway ~debug_data writer last_stream error_code

let handle_stream_error (state : ('a, 'b) State.t) stream_id code =
  write_rst_stream state.writer stream_id code;
  {
    state with
    streams = Streams.stream_transition state.streams stream_id Closed;
  }

let process_preface_settings ?user_settings ~socket ~receive_buffer () =
  let rec parse_loop read_off total_consumed total_read continue_opt =
    let read_len =
      Eio.Flow.single_read socket
        (Cstruct.sub receive_buffer read_off
           (Cstruct.length receive_buffer - read_off))
    in

    match
      Parse.parse_frame
        (Cstruct.sub receive_buffer read_off read_len)
        continue_opt
    with
    | `Fail _ -> Error (Error_code.ProtocolError, "invalid client preface")
    | `Partial (consumed, continue) ->
        parse_loop consumed
          (total_consumed + consumed)
          (total_read + read_len) (Some continue)
    | `Complete (consumed, { Frame.frame_payload = Settings settings_list; _ })
      -> (
        let peer_settings = Settings.(update_with_list default settings_list) in
        let open Writer in
        let writer = create (peer_settings.max_frame_size + 9) in

        (match user_settings with
        | Some user_settings -> write_settings writer user_settings
        | None -> ());
        write_settings_ack writer;
        write_window_update writer Stream_identifier.connection
          Flow_control.WindowSize.initial_increment;
        match write writer socket with
        | Ok () ->
            let rest_off = read_off + total_consumed + consumed in
            let rest_len = total_read + read_len - rest_off in

            Ok
              ( peer_settings,
                Cstruct.sub receive_buffer rest_off rest_len,
                writer )
        | Error msg -> Error (Error_code.ConnectError, msg))
    | `Complete (_, _) ->
        Error (Error_code.ProtocolError, "invalid client preface")
  in
  parse_loop 0 0 0 None

let body_writer_handler ?(debug = false)
    (f : unit -> Types.body_writer_fragment) id =
  let _ = debug in
  let res, on_flush = f () in

  fun (state : ('a, 'b) State.t) ->
    let state =
      { state with flush_thunk = Util.merge_thunks state.flush_thunk on_flush }
    in
    let stream_flow = Streams.flow_of_id state.streams id in
    let max_frame_size = state.peer_settings.max_frame_size in
    match res with
    | `Data cs_list -> (
        let total_len =
          List.fold_left (fun acc cs -> cs.Cstruct.len + acc) 0 cs_list
        in

        match
          Flow_control.incr_sent stream_flow (Int32.of_int total_len)
            ~initial_window_size:state.peer_settings.initial_window_size
        with
        (* | Error _ -> failwith "window overflow 1, report to user" *)
        | _ ->
            let distributed = Util.split_cstructs cs_list max_frame_size in
            List.iteri
              (fun _ (cs_list, len) ->
                write_data ~end_stream:false state.writer id len cs_list
                (* if i < List.length distributed - 1 then write () *))
              distributed;

            (* { *)
            (*   state with *)
            (*   streams = Streams.update_stream_flow state.streams id new_flow; *)
            (* } *)
            state)
    | `End (Some cs_list, trailers) -> (
        let send_trailers = List.length trailers > 0 in
        let total_len =
          List.fold_left (fun acc cs -> cs.Cstruct.len + acc) 0 cs_list
        in
        match
          Flow_control.incr_sent stream_flow (Int32.of_int total_len)
            ~initial_window_size:state.peer_settings.initial_window_size
        with
        | Error _ -> failwith "window overflow 2, report to user"
        | Ok new_flow -> (
            let distributed = Util.split_cstructs cs_list max_frame_size in
            List.iteri
              (fun _ (cs_list, len) ->
                write_data ~end_stream:(not send_trailers) state.writer id len
                  cs_list
                (* if i < List.length distributed - 1 then write () *))
              distributed;

            if send_trailers then
              write_trailers state.writer state.hpack_encoder id trailers;
            let updated_streams =
              Streams.update_stream_flow state.streams id new_flow
            in
            match Streams.state_of_id updated_streams id with
            | Open (stream_reader, _) ->
                {
                  state with
                  streams =
                    Streams.stream_transition updated_streams id
                      (HalfClosed (Local stream_reader));
                }
            | _ ->
                {
                  state with
                  streams = Streams.stream_transition updated_streams id Closed;
                }))
    | `End (None, trailers) -> (
        let send_trailers = List.length trailers > 0 in
        if send_trailers then
          write_trailers state.writer state.hpack_encoder id trailers
        else write_data ~end_stream:true state.writer id 0 [ Cstruct.empty ];
        match Streams.state_of_id state.streams id with
        | Open (stream_reader, _) ->
            {
              state with
              streams =
                Streams.stream_transition state.streams id
                  (HalfClosed (Local stream_reader));
            }
        | _ ->
            {
              state with
              streams = Streams.stream_transition state.streams id Closed;
            })
    | `Yield -> Eio.Fiber.await_cancel ()

let user_goaway_handler ~f =
  f ();
  fun state ->
    write_goaway state.State.writer state.streams.last_peer_stream
      Error_code.NoError;
    { state with shutdown = true }

let read_io ~debug ~frame_handler (state : ('a, 'b) State.t) cs =
  match Parse.read_frames cs state.parse_state with
  | Ok (consumed, frames, continue_opt) ->
      let _ = debug in
      let state_with_parse = { state with parse_state = continue_opt } in
      let next_state =
        List.fold_left
          (fun state frame ->
            match state with
            | None -> None
            | Some state -> frame_handler frame state)
          (Some state_with_parse) frames
      in

      (consumed, next_state)
  | Error err -> (
      match err with
      | _, Error.ConnectionError err ->
          handle_connection_error ~state err;
          (0, None)
      | consumed, StreamError (stream_id, code) ->
          (consumed, Some (handle_stream_error state stream_id code)))

let frame_handler ~process_complete_headers ~process_data_frame ~error_handler
    (frame : Frame.t) (state : ('a, 'b) State.t) =
  let connection_error code msg =
    handle_connection_error ~state (code, msg);
    None
  in
  let stream_error id code = Some (handle_stream_error state id code) in
  let next_step next_state = Some next_state in

  let process_complete_headers =
    process_complete_headers state stream_error connection_error next_step
  in
  let process_data_frame =
    process_data_frame state stream_error connection_error next_step
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
    let { Frame.flags; _ } = frame_header in
    if not (Flags.test_end_header flags) then (
      let headers_buffer = Bigstringaf.create 10000 in
      let len = Bigstringaf.length bs in
      Bigstringaf.blit bs ~src_off:0 headers_buffer ~dst_off:0 ~len;

      next_step { state with headers_state = InProgress (headers_buffer, len) })
    else
      match
        decompress_headers_block bs ~len:(Bigstringaf.length bs)
          state.hpack_decoder
      with
      | Error msg -> connection_error Error_code.CompressionError msg
      | Ok headers -> process_complete_headers frame_header headers
  in

  let process_continuation_frame frame_header bs =
    let { Frame.flags; _ } = frame_header in
    match state.headers_state with
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
            { state with headers_state = InProgress (new_buffer, new_len) }
        else
          match
            decompress_headers_block new_buffer ~len:new_len state.hpack_decoder
          with
          | Error msg -> connection_error Error_code.CompressionError msg
          | Ok headers -> process_complete_headers frame_header headers)
  in

  let process_settings_frame { Frame.flags; _ } settings_list =
    match (state.settings_status, Flags.test_ack flags) with
    | _, false -> (
        match State.update_state_with_peer_settings state settings_list with
        | Error msg -> connection_error Error_code.InternalError msg
        | Ok new_state ->
            write_settings_ack state.writer;
            next_step new_state)
    | Syncing new_settings, true ->
        let new_state =
          {
            state with
            local_settings =
              Settings.(update_with_list state.local_settings new_settings);
            settings_status = Idle;
          }
        in

        next_step new_state
    | Idle, true ->
        connection_error Error_code.ProtocolError
          "Unexpected ACK flag in SETTINGS frame."
  in

  let process_rst_stream_frame { Frame.stream_id; _ } error_code =
    match Streams.state_of_id state.streams stream_id with
    | Idle ->
        connection_error Error_code.ProtocolError
          "RST_STREAM received on a idle stream"
    | Closed ->
        connection_error Error_code.StreamClosed
          "RST_STREAM received on a closed stream!"
    | _ -> (
        error_handler (Error.StreamError (stream_id, error_code));
        let streams =
          Streams.stream_transition state.streams stream_id Closed
        in
        match (state.shutdown, Streams.all_closed streams) with
        | true, true -> None
        | _ -> next_step { state with streams })
  in

  let process_goaway_frame payload =
    (* TODO: we should "cancel" whatever requests were sent with stream_id greater than _last_stream_id *)
    let _last_stream_id, code, msg = payload in
    match code with
    | Error_code.NoError -> (
        (* graceful shutdown *)
        match Streams.all_closed state.streams with
        | false ->
            let new_state = { state with shutdown = true } in
            next_step new_state
        | true -> None)
    | _ ->
        error_handler (Error.ConnectionError (code, Bigstringaf.to_string msg));
        None
  in

  let process_window_update_frame { Frame.stream_id; _ } increment =
    if Stream_identifier.is_connection stream_id then
      next_step
        { state with flow = Flow_control.incr_out_flow state.flow increment }
    else
      match Streams.state_of_id state.streams stream_id with
      | Open _ | Reserved Local | HalfClosed _ ->
          next_step
            {
              state with
              streams =
                Streams.incr_stream_out_flow state.streams stream_id increment;
            }
      | _ ->
          connection_error Error_code.ProtocolError "unexpected WINDOW_UPDATE"
  in

  let { Frame.frame_payload; frame_header } = frame in
  match (state.headers_state, frame_payload) with
  | InProgress _, Continuation _ | Idle, _ -> (
      match frame_payload with
      | Data payload -> process_data_frame frame_header payload
      | Settings payload -> process_settings_frame frame_header payload
      | Ping bs ->
          write_ping state.writer bs ~ack:true;
          next_step state
      | Headers payload -> process_headers_frame frame_header payload
      | Continuation payload -> process_continuation_frame frame_header payload
      | RSTStream payload -> process_rst_stream_frame frame_header payload
      | PushPromise _ ->
          connection_error Error_code.ProtocolError "client cannot push"
      | GoAway payload -> process_goaway_frame payload
      | WindowUpdate payload -> process_window_update_frame frame_header payload
      | Unknown _ -> next_step state
      | Priority -> next_step state)
  | InProgress _, _ ->
      connection_error Error_code.ProtocolError
        "unexpected frame other than CONTINUATION in the middle of headers \
         block"
