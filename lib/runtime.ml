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
     let debug_data =
       Bigstringaf.of_string ~off:0 ~len:(String.length msg) msg
     in
     write_goaway ~debug_data writer last_peer_stream code

let handle_stream_error (state : _ State.t) stream_id code =
  write_rst_stream state.writer stream_id code;
  (* FIXME: handler stream error on "protocol errors" with user error handler and pass the context to final contexts here *)
  {
    state with
    streams = Streams.stream_transition state.streams stream_id (State Closed);
  }

let step iter_result state = { iter_result; state }

let step_connection_error state code msg =
  { iter_result = ConnectionError (ProtocolViolation (code, msg)); state }

let step_stream_error state id code =
  { iter_result = InProgress; state = handle_stream_error state id code }

let map_transition : ('a t -> 'a t) -> 'a t -> 'a t step =
 fun f state -> step InProgress (f state)

let map_event : (unit -> 'a t -> 'a t) -> unit -> 'a t -> 'a t step =
 fun f () -> map_transition (f ())

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
          (Error.ProtocolViolation (ProtocolError, "invalid client preface"))
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
        |> Result.map_error (fun exn -> Error.Exn exn)
        |> Result.map (fun () ->
               let rest_off = read_off + total_consumed + consumed in
               let rest_len = total_read + read_len - rest_off in

               ( peer_settings,
                 Cstruct.sub receive_buffer rest_off rest_len,
                 writer ))
    | `Complete (_, _) ->
        Error (ProtocolViolation (ProtocolError, "invalid client preface"))
  in
  parse_loop 0 0 0 None

let process_data_frame :
    'a t -> Frame.frame_header -> Bigstringaf.t -> 'a t step =
 fun state { Frame.flags; stream_id; _ } bs ->
  let open Writer in
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in
  let (State stream_state) = Streams.state_of_id state.streams stream_id in
  match (stream_state, end_stream) with
  | Idle, _ | HalfClosed (Remote _), _ ->
      connection_error Error_code.StreamClosed
        "DATA frame received on closed stream!"
  | Reserved _, _ ->
      connection_error Error_code.ProtocolError
        "DATA frame received on reserved stream"
  | Closed, _ ->
      connection_error Error_code.StreamClosed
        "DATA frame received on closed stream!"
  | ( Open
        {
          readers = BodyReader reader;
          writers;
          error_handler;
          on_close;
          context;
        },
      true ) ->
      let new_context =
        reader (reader context (`Data (Cstruct.of_bigarray bs))) (`End [])
      in
      step InProgress
        {
          state with
          streams =
            Streams.(
              stream_transition state.streams stream_id
                (State
                   (HalfClosed
                      (Remote
                         {
                           writers;
                           error_handler;
                           on_close;
                           context = new_context;
                         })))
              |> update_flow_on_data
                   ~send_update:(write_window_update state.writer stream_id)
                   stream_id
                   (Bigstringaf.length bs |> Int32.of_int));
          flow =
            Flow_control.receive_data
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              state.flow
              (Bigstringaf.length bs |> Int32.of_int);
        }
  | ( HalfClosed (Local { readers = BodyReader reader; on_close; context; _ }),
      true ) ->
      let new_context =
        reader (reader context (`Data (Cstruct.of_bigarray bs))) (`End [])
      in

      let streams =
        Streams.(
          stream_transition state.streams stream_id (State Closed)
          |> update_flow_on_data
               ~send_update:(write_window_update state.writer stream_id)
               stream_id
               (Bigstringaf.length bs |> Int32.of_int))
      in
      on_close new_context;
      step InProgress
        {
          state with
          streams;
          flow =
            Flow_control.receive_data state.flow
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              (Bigstringaf.length bs |> Int32.of_int);
        }
  | Open ({ readers = BodyReader reader; context; _ } as state'), false ->
      let streams =
        (if Stream_identifier.is_client stream_id then
           Streams.update_last_local_stream stream_id state.streams
         else Streams.update_last_peer_stream state.streams stream_id)
        |> Streams.update_flow_on_data
             ~send_update:(write_window_update state.writer stream_id)
             stream_id
             (Bigstringaf.length bs |> Int32.of_int)
      in
      let new_context = reader context (`Data (Cstruct.of_bigarray bs)) in
      step InProgress
        {
          state with
          streams =
            Streams.stream_transition streams stream_id
              (State (Open { state' with context = new_context }));
          flow =
            Flow_control.receive_data state.flow
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              (Bigstringaf.length bs |> Int32.of_int);
        }
  | ( HalfClosed (Local ({ readers = BodyReader reader; context; _ } as state')),
      false ) ->
      let streams =
        (if Stream_identifier.is_client stream_id then
           Streams.update_last_local_stream stream_id state.streams
         else Streams.update_last_peer_stream state.streams stream_id)
        |> Streams.update_flow_on_data
             ~send_update:(write_window_update state.writer stream_id)
             stream_id
             (Bigstringaf.length bs |> Int32.of_int)
      in
      let new_context = reader context (`Data (Cstruct.of_bigarray bs)) in
      step InProgress
        {
          state with
          streams =
            Streams.stream_transition streams stream_id
              (State (HalfClosed (Local { state' with context = new_context })));
          flow =
            Flow_control.receive_data state.flow
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              (Bigstringaf.length bs |> Int32.of_int);
        }
  | Open _, _ | HalfClosed (Local _), _ ->
      stream_error stream_id Error_code.ProtocolError

let frame_handler ~process_complete_headers (frame : Frame.t)
    (state : _ State.t) : _ step =
  let connection_error = step_connection_error state in
  let process_complete_headers = process_complete_headers state in
  let process_data_frame = process_data_frame state in

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
    let (State stream_state) = Streams.state_of_id state.streams stream_id in
    match stream_state with
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
        (* TODO: here we should run the on_close stream callback with the _new_context *)
        let _new_context =
          error_handler context (StreamError (stream_id, error_code))
        in
        let streams =
          Streams.stream_transition state.streams stream_id (State Closed)
        in
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
      match Streams.state_of_id state.streams stream_id with
      | State (Open _) | State (Reserved (Local _)) | State (HalfClosed _) ->
          step InProgress
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

let body_writer_handler (type p) :
    state_on_data:p Streams.Stream.state ->
    state_on_end:p Streams.Stream.state ->
    _ Body.writer_payload ->
    Stream_identifier.t ->
    (unit -> unit) ->
    (unit -> unit) ->
    p t ->
    p t =
 fun ~state_on_data ~state_on_end res id on_flush on_close ->
  fun state ->
   let state =
     { state with flush_thunk = Util.merge_thunks state.flush_thunk on_flush }
   in
   let max_frame_size = state.peer_settings.max_frame_size in

   match res with
   | `Data cs_list ->
       let distributed = Util.split_cstructs cs_list max_frame_size in
       List.iteri
         (fun _ (cs_list, len) ->
           write_data ~end_stream:false state.writer id len cs_list)
         distributed;

       {
         state with
         streams = Streams.stream_transition state.streams id state_on_data;
       }
   | `End (Some cs_list, trailers) ->
       let send_trailers = List.length trailers > 0 in
       let distributed = Util.split_cstructs cs_list max_frame_size in
       List.iteri
         (fun i (cs_list, len) ->
           write_data
             ~end_stream:((not send_trailers) && i = List.length distributed - 1)
             state.writer id len cs_list)
         distributed;

       if send_trailers then
         write_trailers state.writer state.hpack_encoder id trailers;
       (match state_on_end with State Closed -> on_close () | _ -> ());
       {
         state with
         streams = Streams.stream_transition state.streams id state_on_end;
       }
   | `End (None, trailers) ->
       let send_trailers = List.length trailers > 0 in
       if send_trailers then
         write_trailers state.writer state.hpack_encoder id trailers
       else write_data ~end_stream:true state.writer id 0 [ Cstruct.empty ];
       (match state_on_end with State Closed -> on_close () | _ -> ());
       {
         state with
         streams = Streams.(stream_transition state.streams id state_on_end);
       }

let make_body_writer_event (type p) :
    p Streams.Stream.t ->
    Stream_identifier.t ->
    (unit -> p t -> p t step) option =
 fun stream id ->
  match stream.state with
  | State
      (Open
         ({
            writers = BodyWriter body_writer;
            readers;
            error_handler;
            context;
            on_close;
          } as state')) ->
      Some
        (fun () ->
          let { Body.payload = res; on_flush; context = new_context } =
            body_writer context
          in

          body_writer_handler
            ~state_on_data:(State (Open { state' with context = new_context }))
            ~state_on_end:
              (State
                 (HalfClosed
                    (Local { context; error_handler; readers; on_close })))
            res id on_flush
            (fun () -> on_close context)
          |> map_transition)
  | State
      (HalfClosed
         (Remote
            ({ writers = BodyWriter body_writer; on_close; context; _ } as
             state'))) ->
      Some
        (fun () ->
          let { Body.payload = res; on_flush; context = new_context } =
            body_writer context
          in

          body_writer_handler
            ~state_on_data:
              (State (HalfClosed (Remote { state' with context = new_context })))
            ~state_on_end:(State Closed) res id on_flush
            (fun () -> on_close context)
          |> map_transition)
  | _ -> None

let user_goaway_handler ~f =
 fun () ->
  f ();
  fun state ->
    write_goaway state.State.writer state.streams.last_peer_stream
      Error_code.NoError;
    { state with shutdown = true }

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

let get_body_writers : _ t -> (unit -> _ t -> _ t step) list =
 fun state ->
  Streams.StreamMap.fold
    (fun id stream acc ->
      match make_body_writer_event stream id with
      | Some event -> event :: acc
      | None -> acc)
    state.streams.map []

let finalize_iteration :
    _ Eio.Resource.t ->
    ('peer t -> 'i list -> 'i Types.iteration) ->
    'peer t step ->
    'i Types.iteration =
 fun socket continue { iter_result; state } ->
  (match iter_result with
  | ConnectionError err ->
      handle_connection_error ~last_peer_stream:state.streams.last_peer_stream
        ~writer:state.writer err
  | _ -> ());
  let write_result = write state.writer socket in
  let state = do_flush state in
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

let start :
    'peer.
    initial_state_result:('peer t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> 'peer t -> 'peer t step) ->
    receive_buffer:Cstruct.t ->
    user_events_handlers:('peer t -> (unit -> 'peer t -> 'peer t step) list) ->
    input_handler:('peer t -> 't -> 'peer t) ->
    _ Eio.Resource.t ->
    'i Types.iteration =
 fun ~initial_state_result ~frame_handler ~receive_buffer ~user_events_handlers
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
           :: List.concat [ user_events_handlers state; get_body_writers state ]
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
      let writer = create Settings.default.max_frame_size in
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
