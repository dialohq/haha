open Writer
open State

type iteration_result =
  | End
  | InProgress
  | ConnectionError of Error.connection_error

type 'state step = { iter_result : iteration_result; state : 'state }

let handle_connection_error ?(last_peer_stream = Int32.zero) ~writer error =
  let codemsg_opt =
    match error with
    | Error.ProtocolViolation err -> Some err
    | Exn exn ->
        Some
          ( InternalError,
            Format.sprintf "internal exception: %s" (Printexc.to_string exn) )
    | _ -> None
  in

  codemsg_opt
  |> Option.iter @@ fun (code, msg) ->
     let debug_data = Cstruct.of_string ~off:0 ~len:(String.length msg) msg in
     write_goaway ~debug_data writer last_peer_stream code

let handle_stream_error (state : _ State.t) stream_id code =
  write_rst_stream state.writer stream_id code;
  {
    state with
    streams =
      Streams.close_stream
        ~err:(StreamError (stream_id, code))
        stream_id state.streams;
  }

let step iter_result state = { iter_result; state }

let step_connection_error state code msg =
  { iter_result = ConnectionError (ProtocolViolation (code, msg)); state }

let step_stream_error state id code =
  { iter_result = InProgress; state = handle_stream_error state id code }

let map_transition : ('a t -> 'a t) -> 'a t -> 'a t step =
 fun f state -> step InProgress (f state)

let map_streams_transitions :
    (unit -> 'p Streams.t -> 'p Streams.t) list ->
    (unit -> 'p t -> 'p t step) list =
 fun transitions ->
  List.map
    (fun tran () ->
      let f = tran () in
      fun state ->
        {
          iter_result = InProgress;
          state = { state with streams = f state.streams };
        })
    transitions

let process_preface_settings ?user_settings ~socket ~receive_buffer () =
  let rec parse_loop read_off total_consumed total_read continue_opt =
    try
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
      | `Fail _ ->
          Stdlib.Error
            (Error.ProtocolViolation (ProtocolError, "invalid client preface"))
      | `Partial (consumed, continue) ->
          parse_loop consumed
            (total_consumed + consumed)
            (total_read + read_len) (Some continue)
      | `Complete (consumed, { Frame.frame_payload = Settings settings_list; _ })
        ->
          let peer_settings =
            Settings.(update_with_list default settings_list)
          in
          let open Writer in
          let writer =
            create ~header_table_size:peer_settings.header_table_size
              (peer_settings.max_frame_size + 9)
          in

          (match user_settings with
          | Some user_settings -> write_settings writer user_settings
          | None -> ());
          write_settings_ack writer;
          write_window_update writer Stream_identifier.connection
            Flow_control.initial_increment;
          write writer socket
          |> Result.map_error (fun exn -> Error.Exn exn)
          |> Result.map (fun () ->
                 let rest_off = read_off + total_consumed + consumed in
                 let rest_len = total_read + read_len - rest_off in

                 ( peer_settings,
                   Cstruct.sub receive_buffer rest_off rest_len,
                   writer ))
      | `Complete (_, _) ->
          Error (ProtocolViolation (ProtocolError, "invalid client preface"))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Exn exn)
  in
  parse_loop 0 0 0 None

let process_data_frame : 'a t -> Frame.frame_header -> Cstruct.t -> 'a t step =
 fun state { Frame.flags; stream_id; _ } data ->
  match
    Streams.read_data ~writer:state.writer
      ~end_stream:(Flags.test_end_stream flags)
      ~data stream_id state.streams
  with
  | Ok streams ->
      step InProgress
        {
          state with
          streams;
          flow =
            Flow_control.receive_data state.flow
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              (Cstruct.length data |> Int32.of_int);
        }
  | Error err -> { iter_result = ConnectionError err; state }

let frame_handler ~process_complete_headers (frame : Frame.t)
    (state : _ State.t) : _ step =
  let connection_error = step_connection_error state in
  let process_complete_headers = process_complete_headers state in
  let process_data_frame = process_data_frame state in

  let decompress_headers_block bs ~len hpack_decoder =
    let hpack_parser = Hpack.Decoder.decode_headers hpack_decoder in
    let error' ?msg () =
      Stdlib.Error
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
            |> Result.map (fun l ->
                   Headers.of_list
                   @@ List.rev_map
                        (fun hpack_header ->
                          (hpack_header.Hpack.name, hpack_header.value))
                        l))
  in

  let process_headers_frame frame_header bs =
    let { Frame.flags; _ } = frame_header in
    if not (Flags.test_end_header flags) then (
      let headers_buffer = Bigstringaf.create 10000 in
      let len = Bigstringaf.length bs in
      Bigstringaf.blit bs ~src_off:0 headers_buffer ~dst_off:0 ~len;

      step InProgress
        { state with headers_state = InProgress (headers_buffer, len) })
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
          step InProgress
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
            step InProgress new_state)
    | Syncing new_settings, true ->
        let new_state =
          {
            state with
            local_settings =
              Settings.(update_with_list state.local_settings new_settings);
            settings_status = Idle;
          }
        in

        step InProgress new_state
    | Idle, true ->
        connection_error Error_code.ProtocolError
          "Unexpected ACK flag in SETTINGS frame."
  in

  let process_rst_stream_frame { Frame.stream_id; _ } error_code =
    match Streams.receive_rst ~error_code stream_id state.streams with
    | Error err -> { iter_result = ConnectionError err; state }
    | Ok streams -> (
        match (state.shutdown, Streams.all_closed streams) with
        | true, true -> step End state
        | _ -> step InProgress { state with streams })
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
            step InProgress new_state
        | true -> step End state)
    | _ ->
        step
          (ConnectionError (PeerError (code, Bigstringaf.to_string msg)))
          state
  in

  let process_window_update_frame { Frame.stream_id; _ } increment =
    if Stream_identifier.is_connection stream_id then
      step InProgress
        { state with flow = Flow_control.incr_out_flow state.flow increment }
    else
      match Streams.receive_window_update stream_id increment state.streams with
      | Error err -> { iter_result = ConnectionError err; state }
      | Ok streams -> step InProgress { state with streams }
  in

  let { Frame.frame_payload; frame_header } = frame in

  match (state.headers_state, frame_payload) with
  | InProgress _, Continuation _ | Idle, _ -> (
      match frame_payload with
      | Data payload -> process_data_frame frame_header payload
      | Settings payload -> process_settings_frame frame_header payload
      | Ping bs ->
          write_ping state.writer bs ~ack:true;
          step InProgress state
      | Headers payload -> process_headers_frame frame_header payload
      | Continuation payload -> process_continuation_frame frame_header payload
      | RSTStream payload -> process_rst_stream_frame frame_header payload
      | PushPromise _ ->
          connection_error Error_code.ProtocolError "client cannot push"
      | GoAway payload -> process_goaway_frame payload
      | WindowUpdate payload -> process_window_update_frame frame_header payload
      | Unknown _ -> step InProgress state
      | Priority -> step InProgress state)
  | InProgress _, _ ->
      connection_error Error_code.ProtocolError
        "unexpected frame other than CONTINUATION in the middle of headers \
         block"

let parse_and_handle ~frame_handler (state : _ State.t) cs =
  match Parse.read_frames cs state.parse_state with
  | Ok (consumed, frames, continue_opt) ->
      let state_with_parse = { state with parse_state = continue_opt } in
      let next_step =
        List.fold_left
          (fun step frame ->
            match step with
            | { iter_result = InProgress; state } -> frame_handler frame state
            | other -> other)
          { iter_result = InProgress; state = state_with_parse }
          frames
      in

      (consumed, next_step)
  | Error err -> (
      match err with
      | _, Error.ConnectionError err ->
          (0, { iter_result = ConnectionError err; state })
      | consumed, StreamError (stream_id, code) ->
          ( consumed,
            {
              iter_result = InProgress;
              state = handle_stream_error state stream_id code;
            } ))

let read_loop ~socket ~receive_buffer ~frame_handler off () =
  let read_bytes =
    try
      Ok
        (Eio.Flow.single_read socket
           (Cstruct.sub receive_buffer off
              (Cstruct.length receive_buffer - off)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error exn
  in
  fun state ->
    match read_bytes with
    | Error exn -> step (ConnectionError (Exn exn)) state
    | Ok read_bytes -> (
        let consumed, next_step =
          parse_and_handle ~frame_handler state
            (Cstruct.sub receive_buffer 0 (read_bytes + off))
        in
        let unconsumed = read_bytes + off - consumed in
        Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
        match next_step with
        | { iter_result = InProgress; state = next_state } ->
            step InProgress { next_state with read_off = unconsumed }
        | other -> other)

let combine_steps x y =
 fun step ->
  match x step with
  | { iter_result = InProgress; state = new_state } -> y new_state
  | other -> other

let finalize_iteration :
    _ Eio.Resource.t ->
    ('peer t -> 'i list -> 'i Types.iteration) ->
    'peer t step ->
    'i Types.iteration =
 fun socket continue { iter_result; state } ->
  (match iter_result with
  | ConnectionError err ->
      handle_connection_error
        ~last_peer_stream:(Streams.last_peer_stream state.streams)
        ~writer:state.writer err
  | _ -> ());
  let write_result = write state.writer socket in
  let state = do_flush state |> update_closing_streams in
  let active_streams = active_streams state in

  match (iter_result, write_result) with
  | ConnectionError err, _ ->
      error_all err state;
      { active_streams; state = Error err }
  | End, Ok () -> { active_streams; state = End }
  | InProgress, Ok () when state.shutdown && Streams.all_closed state.streams ->
      { active_streams; state = End }
  | (End | InProgress), Error exn ->
      error_all (Exn exn) state;
      { active_streams; state = Error (Exn exn) }
  | InProgress, Ok () -> { active_streams; state = InProgress (continue state) }

let get_body_writers : 'peer t -> (unit -> 'peer t -> 'peer t step) list =
 fun { writer; peer_settings; streams; _ } ->
  Streams.body_writers_transitions ~writer
    ~max_frame_size:peer_settings.max_frame_size streams
  |> map_streams_transitions

let start :
    'peer.
    ?extra_events_handlers:('peer t -> (unit -> 'peer t -> 'peer t step) list) ->
    initial_state_result:('peer t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> 'peer t -> 'peer t step) ->
    receive_buffer:Cstruct.t ->
    input_handler:('peer t -> 't -> 'peer t) ->
    _ Eio.Resource.t ->
    'i Types.iteration =
 fun ?extra_events_handlers ~initial_state_result ~frame_handler ~receive_buffer
     ~input_handler socket ->
  let process_inputs : 'i list -> 'peer t -> 'peer t step =
   fun inputs ->
    (fun state -> List.fold_left input_handler state inputs) |> map_transition
  in

  let rec process_events : 'peer t -> 'i list -> 'i Types.iteration =
   fun state -> function
     | [] ->
         let events =
           read_loop ~receive_buffer ~socket ~frame_handler state.read_off
           ::
           (match extra_events_handlers with
           | None -> get_body_writers state
           | Some extra -> List.concat [ get_body_writers state; extra state ])
         in

         let next_step = Eio.Fiber.any ~combine:combine_steps events in

         Eio.Cancel.protect @@ fun () ->
         finalize_iteration socket process_events (next_step state)
     | inputs ->
         Eio.Cancel.protect @@ fun () ->
         finalize_iteration socket process_events (process_inputs inputs state)
  in

  match initial_state_result with
  | Error err ->
      let writer =
        create ~header_table_size:Settings.default.header_table_size
          Settings.default.max_frame_size
      in
      handle_connection_error ~writer err;
      write writer socket |> ignore;
      { active_streams = 0; state = Error err }
  | Ok (initial_state, rest_to_parse) ->
      if Cstruct.length rest_to_parse > 0 then
        let step =
          match parse_and_handle ~frame_handler initial_state rest_to_parse with
          | consumed, { iter_result = InProgress; state = next_state } ->
              step InProgress
                {
                  next_state with
                  read_off = rest_to_parse.Cstruct.len - consumed;
                }
          | _, step -> step
        in
        finalize_iteration socket process_events step
      else
        {
          active_streams = 0;
          state = InProgress (process_events initial_state);
        }
