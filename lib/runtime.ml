open Writer
open State

type ('r, 'w, 'context) step =
  | End of 'context final_contexts
  | ConnectionError of (Error.connection_error * 'context final_contexts)
  | NextState of ('r, 'w, 'context) t

let handle_connection_error ?state error =
  let error_code, msg =
    match error with
    | Error.ProtocolError err -> err
    | Exn exn ->
        ( Error_code.InternalError,
          Format.sprintf "internal exception: %s" (Printexc.to_string exn) )
  in

  let last_stream =
    match state with
    | None -> Int32.zero
    | Some state -> state.State.streams.last_peer_stream
  in
  let debug_data = Bigstringaf.of_string ~off:0 ~len:(String.length msg) msg in
  match state with
  | Some { writer; _ } -> write_goaway ~debug_data writer last_stream error_code
  | None ->
      let writer = create (9 + 4 + 4 + String.length msg) in
      write_goaway ~debug_data writer last_stream error_code

let handle_stream_error (state : ('a, 'b, 'c) State.t) stream_id code =
  write_rst_stream state.writer stream_id code;
  (* FIXME: handler stream error on "protocol errors" with user error handler and pass the context to final contexts here *)
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
    | `Fail _ ->
        Stdlib.Error
          (Error.ProtocolError
             (Error_code.ProtocolError, "invalid client preface"))
    | `Partial (consumed, continue) ->
        parse_loop consumed
          (total_consumed + consumed)
          (total_read + read_len) (Some continue)
    | `Complete (consumed, { Frame.frame_payload = Settings settings_list; _ })
      ->
        let peer_settings = Settings.(update_with_list default settings_list) in
        let open Writer in
        let writer = create (peer_settings.max_frame_size + 9) in

        (match user_settings with
        | Some user_settings -> write_settings writer user_settings
        | None -> ());
        write_settings_ack writer;
        write_window_update writer Stream_identifier.connection
          Flow_control.WindowSize.initial_increment;
        write writer socket
        |> Result.map (fun () ->
               let rest_off = read_off + total_consumed + consumed in
               let rest_len = total_read + read_len - rest_off in

               ( peer_settings,
                 Cstruct.sub receive_buffer rest_off rest_len,
                 writer ))
    | `Complete (_, _) ->
        Error
          (Error.ProtocolError
             (Error_code.ProtocolError, "invalid client preface"))
  in
  parse_loop 0 0 0 None

let body_writer_handler ?(debug = false)
    (f : unit -> _ Types.body_writer_fragment) id =
  let _ = debug in
  let res, on_flush, new_context = f () in

  fun (state : ('a, 'b, 'c) State.t) ->
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
            {
              state with
              streams = Streams.update_context id new_context state.streams;
            })
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
            | Open { readers; error_handler; _ } ->
                {
                  state with
                  streams =
                    Streams.stream_transition updated_streams id
                      (HalfClosed
                         (Local
                            { readers; error_handler; context = new_context }));
                }
            | _ ->
                {
                  state with
                  streams =
                    Streams.(stream_transition updated_streams id Closed);
                  final_contexts = (id, new_context) :: state.final_contexts;
                }))
    | `End (None, trailers) -> (
        let send_trailers = List.length trailers > 0 in
        if send_trailers then
          write_trailers state.writer state.hpack_encoder id trailers
        else write_data ~end_stream:true state.writer id 0 [ Cstruct.empty ];
        match Streams.state_of_id state.streams id with
        | Open { readers; error_handler; _ } ->
            {
              state with
              streams =
                Streams.(
                  stream_transition state.streams id
                    (HalfClosed
                       (Local { readers; error_handler; context = new_context })));
            }
        | _ ->
            {
              state with
              streams = Streams.(stream_transition state.streams id Closed);
              final_contexts = (id, new_context) :: state.final_contexts;
            })
    | `Yield -> Eio.Fiber.await_cancel ()

let user_goaway_handler ~f =
  f ();
  fun state ->
    write_goaway state.State.writer state.streams.last_peer_stream
      Error_code.NoError;
    { state with shutdown = true }

let read_io ~debug ~frame_handler (state : ('a, 'b, 'c) State.t) cs =
  match Parse.read_frames cs state.parse_state with
  | Ok (consumed, frames, continue_opt) ->
      let _ = debug in
      let state_with_parse = { state with parse_state = continue_opt } in
      let next_step =
        List.fold_left
          (fun state frame ->
            match state with
            | NextState state -> frame_handler frame state
            | other -> other)
          (NextState state_with_parse) frames
      in

      (consumed, next_step)
  | Error err -> (
      match err with
      | _, Error.ConnectionError err ->
          handle_connection_error ~state err;
          (0, ConnectionError (err, state.final_contexts))
      | consumed, StreamError (stream_id, code) ->
          (consumed, NextState (handle_stream_error state stream_id code)))

let frame_handler ~process_complete_headers ~process_data_frame
    (frame : Frame.t) (state : _ State.t) : _ step =
  let connection_error code msg =
    let err = Error.ProtocolError (code, msg) in
    handle_connection_error ~state err;
    ConnectionError (err, state.final_contexts)
  in
  let stream_error id code = NextState (handle_stream_error state id code) in
  let next_step next_state = NextState next_state in

  let process_complete_headers =
    process_complete_headers state stream_error connection_error next_step
  in
  let process_data_frame =
    process_data_frame state stream_error connection_error next_step
  in
  let decompress_headers_block bs ~len hpack_decoder =
    let hpack_parser = Hpackv.Decoder.decode_headers hpack_decoder in
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
            |> Result.map
                 (List.map (fun hpack_header ->
                      {
                        Header.name = hpack_header.Hpackv.name;
                        value = hpack_header.value;
                      })))
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
    | Open { error_handler; context; _ }
    | HalfClosed
        ( Remote { error_handler; context; _ }
        | Local { error_handler; context; _ } )
    | Reserved
        ( Remote { error_handler; context; _ }
        | Local { error_handler; context; _ } ) -> (
        let new_context = error_handler context error_code in
        let streams =
          Streams.stream_transition state.streams stream_id Closed
        in
        match (state.shutdown, Streams.all_closed streams) with
        | true, true -> End ((stream_id, new_context) :: state.final_contexts)
        | _ ->
            next_step
              {
                state with
                streams;
                final_contexts =
                  (stream_id, new_context) :: state.final_contexts;
              })
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
        | true -> End state.final_contexts)
    | _ ->
        let err = Error.ProtocolError (code, Bigstringaf.to_string msg) in
        (* error_handler err; *)
        ConnectionError (err, state.final_contexts)
  in

  let process_window_update_frame { Frame.stream_id; _ } increment =
    if Stream_identifier.is_connection stream_id then
      next_step
        { state with flow = Flow_control.incr_out_flow state.flow increment }
    else
      match Streams.state_of_id state.streams stream_id with
      | Open _ | Reserved (Local _) | HalfClosed _ ->
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

open Eio

let start :
    'a 'b 'c.
    initial_state_result:
      (('a, 'b, 'c) t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> ('a, 'b, 'c) t -> ('a, 'b, 'c) step) ->
    receive_buffer:Cstruct.t ->
    user_functions_handlers:
      (('a, 'b, 'c) t -> (unit -> ('a, 'b, 'c) t -> ('a, 'b, 'c) t) list) ->
    debug:bool ->
    _ Eio.Resource.t ->
    'c Types.iteration =
 fun ~initial_state_result ~frame_handler ~receive_buffer
     ~user_functions_handlers ~debug socket ->
  let read_loop off =
    let read_bytes =
      try
        Ok
          (Flow.single_read socket
             (Cstruct.sub receive_buffer off
                (Cstruct.length receive_buffer - off)))
      with
      (* NOTE: we might want to do other error handling for specific exceptions *)
      | Eio.Cancel.Cancelled _ as e -> raise e
      | End_of_file as exn -> Error exn
      | Eio.Io (Eio.Net.(E (Connection_reset _)), _) as exn -> Error exn
      | exn -> Error exn
    in
    fun state ->
      match read_bytes with
      | Error exn ->
          let err : Error.connection_error = Exn exn in
          handle_connection_error ~state err;
          ConnectionError (err, state.final_contexts)
      | Ok read_bytes -> (
          let consumed, next_state =
            read_io ~debug ~frame_handler state
              (Cstruct.sub receive_buffer 0 (read_bytes + off))
          in
          let unconsumed = read_bytes + off - consumed in
          Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
          match next_state with
          | NextState next_state ->
              NextState { next_state with read_off = unconsumed }
          | other -> other)
  in

  let flush_write : ('a, 'b, 'c) t -> ('a, 'b, 'c) step =
   fun state ->
    match Writer.write state.writer socket with
    | Ok () ->
        if state.shutdown && Streams.all_closed state.streams then (
          Faraday.close (do_flush state).writer.faraday;
          End state.final_contexts)
        else NextState (do_flush state)
    | Error err ->
        handle_connection_error ~state err;
        Faraday.close state.writer.faraday;
        ConnectionError (err, state.final_contexts)
  in

  let make_events state =
    let base_op () = read_loop state.read_off in

    let opt_functions =
      user_functions_handlers state
      |> List.map (fun f () ->
             let handler = f () in
             fun state -> flush_write (handler state))
    in

    base_op :: opt_functions
  in

  let combine x y =
   fun step ->
    match x step with NextState new_state -> y new_state | other -> other
  in

  let rec process_events : ('a, 'b, 'c) t -> 'c Types.iteration =
   fun state ->
    match (Fiber.any ~combine (make_events state)) state with
    | ConnectionError (err, closed_ctxs) ->
        Faraday.close state.writer.faraday;
        { closed_ctxs; state = Error err }
    | End closed_ctxs ->
        Faraday.close state.writer.faraday;
        { closed_ctxs; state = End }
    | NextState next_state ->
        let closed_ctxs, next_state = extract_contexts next_state in
        {
          closed_ctxs;
          state = InProgress (fun () -> process_events next_state);
        }
  in

  let init_state : _ Types.iteration =
    match initial_state_result with
    | Error err ->
        handle_connection_error err;
        { closed_ctxs = []; state = Error err }
    | Ok (initial_state, rest_to_parse) ->
        if Cstruct.length rest_to_parse > 0 then
          match read_io ~debug ~frame_handler initial_state rest_to_parse with
          | _, End closed_ctxs -> { closed_ctxs; state = End }
          | _, ConnectionError (err, closed_ctxs) ->
              { closed_ctxs; state = Error err }
          | consumed, NextState next_state ->
              {
                closed_ctxs = [];
                state =
                  InProgress
                    (fun () ->
                      process_events
                        {
                          next_state with
                          read_off = rest_to_parse.Cstruct.len - consumed;
                        });
              }
        else
          {
            closed_ctxs = [];
            state = InProgress (fun () -> process_events initial_state);
          }
  in

  init_state
