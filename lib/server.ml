open Runtime

type 'context state =
  ( 'context Streams.server_reader,
    'context Streams.server_writers,
    'context )
  State.t

type 'context interation = 'context Types.iteration

type 'context stream_state =
  ( 'context Streams.server_reader,
    'context Streams.server_writers,
    'context )
  Streams.Stream.state

let process_data_frame (state : _ state) { Frame.stream_id; flags; _ } bs :
    _ step =
  let open Writer in
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in
  match (Streams.state_of_id state.streams stream_id, end_stream) with
  | Idle, _ | HalfClosed (Remote _), _ ->
      stream_error stream_id Error_code.StreamClosed
  | Reserved _, _ ->
      connection_error Error_code.ProtocolError
        "DATA frame received on reserved stream"
  | Closed, _ ->
      connection_error Error_code.StreamClosed
        "DATA frame received on closed stream!"
  | Open { readers; writers; error_handler; context }, true -> (
      let { Types.action; context = new_context } =
        readers context (`End (Some (Cstruct.of_bigarray bs), []))
      in
      match action with
      | `Continue ->
          step InProgress
            {
              state with
              streams =
                Streams.(
                  stream_transition state.streams stream_id
                    (HalfClosed
                       (Remote { writers; error_handler; context = new_context }))
                  |> update_flow_on_data
                       ~send_update:(write_window_update state.writer stream_id)
                       stream_id
                       (Bigstringaf.length bs |> Int32.of_int));
              flow =
                Flow_control.receive_data
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  state.flow
                  (Bigstringaf.length bs |> Int32.of_int);
            }
      | `Reset ->
          Writer.write_rst_stream state.writer stream_id NoError;
          let streams =
            if Stream_identifier.is_server stream_id then
              Streams.update_last_local_stream stream_id state.streams
            else Streams.update_last_peer_stream state.streams stream_id
          in
          step InProgress
            {
              state with
              streams = Streams.(stream_transition streams stream_id Closed);
              flow =
                Flow_control.receive_data
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  state.flow
                  (Bigstringaf.length bs |> Int32.of_int);
              final_contexts = (stream_id, new_context) :: state.final_contexts;
            })
  | HalfClosed (Local { readers; context; _ }), true ->
      let { Types.context = new_context; _ } : _ Types.body_reader_result =
        readers context (`End (Some (Cstruct.of_bigarray bs), []))
      in
      let streams =
        Streams.(
          stream_transition state.streams stream_id Closed
          |> update_flow_on_data
               ~send_update:(write_window_update state.writer stream_id)
               stream_id
               (Bigstringaf.length bs |> Int32.of_int))
      in
      step InProgress
        {
          state with
          streams;
          flow =
            Flow_control.receive_data
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              state.flow
              (Bigstringaf.length bs |> Int32.of_int);
          final_contexts = (stream_id, new_context) :: state.final_contexts;
        }
  | ( (Open { readers; context; _ } | HalfClosed (Local { readers; context; _ })),
      false ) -> (
      let streams =
        (if Stream_identifier.is_server stream_id then
           Streams.update_last_local_stream stream_id state.streams
         else Streams.update_last_peer_stream state.streams stream_id)
        |> Streams.update_flow_on_data
             ~send_update:(write_window_update state.writer stream_id)
             stream_id
             (Bigstringaf.length bs |> Int32.of_int)
      in
      let { Types.action; context = new_context } =
        readers context (`Data (Cstruct.of_bigarray bs))
      in
      match action with
      | `Continue ->
          step InProgress
            {
              state with
              streams = Streams.update_context stream_id new_context streams;
              flow =
                Flow_control.receive_data
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  state.flow
                  (Bigstringaf.length bs |> Int32.of_int);
            }
      | `Reset ->
          Writer.write_rst_stream state.writer stream_id NoError;
          step InProgress
            {
              state with
              streams = Streams.stream_transition streams stream_id Closed;
              flow =
                Flow_control.receive_data
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  state.flow
                  (Bigstringaf.length bs |> Int32.of_int);
              final_contexts = (stream_id, new_context) :: state.final_contexts;
            })

let process_complete_headers (request_handler : _ Reqd.handler)
    (state : _ state) { Frame.flags; stream_id; _ } header_list : _ step =
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in
  let pseudo_validation = Header.Pseudo.validate_request header_list in

  let stream_state = Streams.state_of_id state.streams stream_id in

  match (end_stream, pseudo_validation) with
  | _, Invalid | false, No_pseudo ->
      stream_error stream_id Error_code.ProtocolError
  | true, No_pseudo -> (
      match stream_state with
      | Open { readers; writers; error_handler; context } -> (
          let { Types.action; context = new_context } =
            readers context (`End (None, header_list))
          in
          match action with
          | `Continue ->
              step InProgress
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams stream_id
                      (HalfClosed
                         (Remote
                            { writers; error_handler; context = new_context }));
                }
          | `Reset ->
              Writer.write_rst_stream state.writer stream_id NoError;
              step InProgress
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams stream_id Closed;
                  final_contexts =
                    (stream_id, new_context) :: state.final_contexts;
                })
      | HalfClosed (Local { readers; context; _ }) ->
          let { Types.context = new_context; _ } : _ Types.body_reader_result =
            readers context (`End (None, header_list))
          in
          let streams =
            Streams.(stream_transition state.streams stream_id Closed)
          in
          step InProgress
            {
              state with
              streams;
              final_contexts = (stream_id, new_context) :: state.final_contexts;
            }
      | Reserved _ -> stream_error stream_id Error_code.StreamClosed
      | Idle -> stream_error stream_id Error_code.ProtocolError
      | Closed | HalfClosed (Remote _) ->
          connection_error Error_code.StreamClosed
            "HEADERS received on a closed stream")
  | end_stream, Valid pseudo -> (
      match stream_state with
      | Idle ->
          let open_streams = Streams.count_open state.streams in
          if
            open_streams
            < Int32.to_int state.local_settings.max_concurrent_streams
          then
            (* TODO: this should be a different type than the exponsed request *)
            let reqd =
              {
                Reqd.meth = Method.of_string pseudo.meth;
                path = pseudo.path;
                authority = pseudo.authority;
                scheme = pseudo.scheme;
                headers = Header.filter_pseudo header_list;
              }
            in

            let {
              Reqd.on_data = readers;
              response_writer;
              error_handler;
              initial_context;
            } =
              request_handler reqd
            in

            let new_stream_state : _ stream_state =
              if end_stream then
                HalfClosed
                  (Remote
                     {
                       writers = WritingResponse response_writer;
                       error_handler;
                       context = initial_context;
                     })
              else
                Open
                  {
                    readers;
                    writers = WritingResponse response_writer;
                    error_handler;
                    context = initial_context;
                  }
            in

            step InProgress
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    new_stream_state;
              }
          else
            connection_error Error_code.ProtocolError
              "MAX_CONCURRENT_STREAMS setting reached"
      | Open _ | HalfClosed (Local _) ->
          stream_error stream_id Error_code.ProtocolError
      | Reserved _ ->
          connection_error Error_code.ProtocolError
            "HEADERS received on reserved stream"
      | HalfClosed (Remote _) | Closed ->
          connection_error Error_code.StreamClosed
            "HEADERS received on closed stream")

let response_writer_handler response_writer reader_opt id error_handler context
    =
  let open Writer in
  let response = response_writer () in

  fun (state : _ state) ->
    write_headers_response state.writer state.hpack_encoder id response;
    match response with
    | `Final { body_writer = Some body_writer; _ } ->
        write_window_update state.writer id
          Flow_control.WindowSize.initial_increment;
        {
          state with
          streams = Streams.change_writer state.streams id body_writer;
        }
    | `Final { body_writer = None; _ } ->
        write_window_update state.writer id
          Flow_control.WindowSize.initial_increment;
        let new_stream_state =
          match reader_opt with
          | None -> Streams.Stream.Closed
          | Some readers ->
              HalfClosed (Local { readers; error_handler; context })
        in
        {
          state with
          streams = Streams.stream_transition state.streams id new_stream_state;
        }
    | `Interim _ -> state

let get_response_writers state =
  let response_writers = Streams.response_writers state.State.streams in

  List.map
    (fun (response_writer, reader_opt, id, error_handler, context) () state ->
      response_writer_handler response_writer reader_opt id error_handler
        context state)
    response_writers

let get_body_writers state =
  Streams.body_writers (`Server state.State.streams)
  |> List.map (fun (f, id) () ->
         let handler = body_writer_handler f id in
         fun state -> handler state)

let connection_handler :
    'c.
    ?config:Settings.t ->
    ?goaway_writer:(unit -> unit) ->
    error_handler:(Error.connection_error -> unit) ->
    'c Reqd.handler ->
    _ Eio.Resource.t ->
    _ =
 fun ?(config = Settings.default) ?goaway_writer ~error_handler request_handler
     socket _ ->
  let frame_handler =
    frame_handler
      ~process_complete_headers:(process_complete_headers request_handler)
      ~process_data_frame
  in

  let user_events_handlers state =
    let writers =
      List.concat [ get_response_writers state; get_body_writers state ]
    in
    (match (state.shutdown, goaway_writer) with
    | true, _ | _, None -> writers
    | false, Some f ->
        (fun () ->
          let handler = user_goaway_handler ~f in
          fun state -> handler state)
        :: writers)
    |> List.map (fun f () ->
           let handler = f () in
           fun state -> step InProgress (handler state))
  in

  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in
  let mstring_len = String.length Frame.connection_preface in

  let initial_state_result :
      (('a, 'b, 'c) State.t * Cstruct.t, Error.connection_error) result =
    Eio.Flow.read_exact socket (Cstruct.sub receive_buffer 0 mstring_len);

    match Parse.magic_parse receive_buffer.buffer ~off:0 ~len:mstring_len with
    | Error _ as err -> err
    | Ok _ -> (
        match
          process_preface_settings ~socket ~receive_buffer ~user_settings ()
        with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial ~user_settings ~peer_settings ~writer,
                rest_to_parse ))
  in

  let initial_step =
    start ~receive_buffer ~frame_handler ~initial_state_result
      ~user_events_handlers socket
  in

  let rec loop : _ interation -> unit =
   fun step ->
    match step with
    | { state = End; _ } -> ()
    | { state = Error err; _ } -> error_handler err
    | { state = InProgress next; _ } -> loop (next ())
  in

  loop initial_step
