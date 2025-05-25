open Runtime

type 'context state =
  ( 'context Streams.client_readers,
    'context Streams.client_writer,
    'context )
  State.t

type 'context iteration = 'context Types.iteration

type 'context stream_state =
  ( 'context Streams.client_readers,
    'context Streams.client_writer,
    'context )
  Streams.Stream.state

let process_data_frame (state : _ state) { Frame.flags; stream_id; _ } bs :
    _ step =
  let open Writer in
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in

  match (Streams.state_of_id state.streams stream_id, end_stream) with
  | Reserved _, _ ->
      connection_error Error_code.ProtocolError
        "DATA frame received on reserved stream"
  | Closed, _ | Idle, _ | HalfClosed (Remote _), _ ->
      connection_error Error_code.StreamClosed
        "DATA frame received on closed stream!"
  | Open { readers = AwaitingResponse _; _ }, _
  | HalfClosed (Local { readers = AwaitingResponse _; _ }), _ ->
      stream_error stream_id Error_code.ProtocolError
  | Open { readers = BodyStream reader; writers; error_handler; context }, true
    -> (
      let { Types.action; context = new_context } =
        reader context (`End (Some (Cstruct.of_bigarray bs), []))
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
          step InProgress
            {
              state with
              streams =
                Streams.(stream_transition state.streams stream_id Closed);
              flow =
                Flow_control.receive_data
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  state.flow
                  (Bigstringaf.length bs |> Int32.of_int);
              final_contexts = (stream_id, new_context) :: state.final_contexts;
            })
  | HalfClosed (Local { readers = BodyStream reader; context; _ }), true ->
      let { Types.context = new_context; _ } : _ Types.body_reader_result =
        reader context (`End (Some (Cstruct.of_bigarray bs), []))
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
            Flow_control.receive_data state.flow
              ~send_update:
                (write_window_update state.writer Stream_identifier.connection)
              (Bigstringaf.length bs |> Int32.of_int);
          final_contexts = (stream_id, new_context) :: state.final_contexts;
        }
  | ( ( Open { readers = BodyStream reader; context; _ }
      | HalfClosed (Local { readers = BodyStream reader; context; _ }) ),
      false ) -> (
      let streams =
        (if Stream_identifier.is_client stream_id then
           Streams.update_last_local_stream stream_id state.streams
         else Streams.update_last_peer_stream state.streams stream_id)
        |> Streams.update_flow_on_data
             ~send_update:(write_window_update state.writer stream_id)
             stream_id
             (Bigstringaf.length bs |> Int32.of_int)
      in
      let { Types.action; context = new_context } =
        reader context (`Data (Cstruct.of_bigarray bs))
      in
      match action with
      | `Continue ->
          step InProgress
            {
              state with
              streams = Streams.update_context stream_id new_context streams;
              flow =
                Flow_control.receive_data state.flow
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  (Bigstringaf.length bs |> Int32.of_int);
            }
      | `Reset ->
          Writer.write_rst_stream state.writer stream_id NoError;
          step InProgress
            {
              state with
              streams = Streams.stream_transition streams stream_id Closed;
              flow =
                Flow_control.receive_data state.flow
                  ~send_update:
                    (write_window_update state.writer
                       Stream_identifier.connection)
                  (Bigstringaf.length bs |> Int32.of_int);
              final_contexts = (stream_id, new_context) :: state.final_contexts;
            })

let process_complete_headers (state : _ state) { Frame.flags; stream_id; _ }
    header_list : _ step =
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in
  let pseudo_validation = Header.Pseudo.validate_response header_list in

  let stream_state = Streams.state_of_id state.streams stream_id in

  match (end_stream, pseudo_validation) with
  | _, Invalid | false, No_pseudo ->
      stream_error stream_id Error_code.ProtocolError
  | true, No_pseudo -> (
      match stream_state with
      | Open { readers = BodyStream reader; writers; error_handler; context }
        -> (
          let { Types.action; context = new_context } =
            reader context (`End (None, header_list))
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
      | HalfClosed (Local { readers = BodyStream reader; context; _ }) ->
          let { Types.context = new_context; _ } : _ Types.body_reader_result =
            reader context (`End (None, header_list))
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
      | Open { readers = AwaitingResponse _; _ }
      | HalfClosed (Local { readers = AwaitingResponse _; _ }) ->
          connection_error Error_code.ProtocolError
            (Format.sprintf
               "received first HEADERS in stream %li with no pseudo-headers"
               stream_id)
      | Reserved _ -> stream_error stream_id Error_code.StreamClosed
      | Idle -> stream_error stream_id Error_code.ProtocolError
      | Closed | HalfClosed (Remote _) ->
          connection_error Error_code.StreamClosed
            "HEADERS received on a closed stream")
  | end_stream, Valid pseudo -> (
      let headers = Header.filter_pseudo header_list in
      let response : _ Response.t =
        match Status.of_code pseudo.status with
        | #Status.informational as status -> `Interim { status; headers }
        | status -> `Final { status; headers; body_writer = None }
      in
      match (stream_state, response) with
      | ( Open { readers = AwaitingResponse response_handler; context; _ },
          `Interim _ )
      | ( HalfClosed
            (Local { readers = AwaitingResponse response_handler; context; _ }),
          `Interim _ ) ->
          let _body_reader, context = response_handler context response in

          let streams =
            Streams.update_context stream_id context state.streams
          in

          step InProgress { state with streams }
      | ( Open
            {
              readers = AwaitingResponse response_handler;
              writers = body_writer;
              error_handler;
              context;
            },
          `Final _ ) ->
          let body_reader, context = response_handler context response in

          let new_stream_state : _ stream_state =
            match (body_reader, end_stream) with
            | None, _ ->
                Writer.write_rst_stream state.writer stream_id NoError;
                Closed
            | Some _, true ->
                HalfClosed
                  (Remote { writers = body_writer; error_handler; context })
            | Some body_reader, false ->
                Open
                  {
                    readers = BodyStream body_reader;
                    writers = body_writer;
                    error_handler;
                    context;
                  }
          in

          step InProgress
            {
              state with
              streams =
                Streams.stream_transition state.streams stream_id
                  new_stream_state;
              final_contexts =
                (match new_stream_state with
                | Closed -> (stream_id, context) :: state.final_contexts
                | _ -> state.final_contexts);
            }
      | ( HalfClosed
            (Local
               {
                 readers = AwaitingResponse response_handler;
                 error_handler;
                 context;
               }),
          `Final _ ) ->
          let body_reader, context = response_handler context response in

          let new_stream_state : _ stream_state =
            match (end_stream, body_reader) with
            | false, None ->
                Writer.write_rst_stream state.writer stream_id NoError;
                Closed
            | false, Some body_reader ->
                HalfClosed
                  (Local
                     {
                       readers = BodyStream body_reader;
                       error_handler;
                       context;
                     })
            | true, _ -> Closed
          in
          let streams =
            Streams.stream_transition state.streams stream_id new_stream_state
          in
          step InProgress
            {
              state with
              streams;
              final_contexts =
                (match new_stream_state with
                | Closed -> (stream_id, context) :: state.final_contexts
                | _ -> state.final_contexts);
            }
      | Open { readers = BodyStream _; _ }, _
      | HalfClosed (Local { readers = BodyStream _; _ }), _ ->
          connection_error Error_code.ProtocolError
            (Format.sprintf
               "unexpected multiple non-informational HEADERS on stream %li"
               stream_id)
      | Idle, _ ->
          connection_error Error_code.ProtocolError
            "unexpected HEADERS response on idle stream"
      | Reserved _, _ ->
          connection_error Error_code.ProtocolError
            "HEADERS received on reserved stream"
      | HalfClosed (Remote _), _ | Closed, _ ->
          connection_error Error_code.StreamClosed
            "HEADERS received on closed stream")

let request_writer_handler request_writer =
 fun () ->
  let req_opt = request_writer () in

  fun (state : _ state) ->
    match req_opt with
    | None ->
        Writer.write_goaway state.writer state.streams.last_peer_stream
          Error_code.NoError;
        let new_state = { state with shutdown = true } in
        new_state
    | Some
        ({
           Request.response_handler;
           body_writer;
           error_handler;
           initial_context;
           _;
         } as request) ->
        let id = Streams.get_next_id state.streams `Client in
        Writer.writer_request_headers state.writer state.hpack_encoder id
          request;
        Writer.write_window_update state.writer id
          Flow_control.WindowSize.initial_increment;
        let stream_state : _ stream_state =
          match body_writer with
          | Some body_writer ->
              Streams.Stream.Open
                {
                  readers = AwaitingResponse response_handler;
                  writers = body_writer;
                  error_handler;
                  context = initial_context;
                }
          | None ->
              HalfClosed
                (Local
                   {
                     readers = AwaitingResponse response_handler;
                     error_handler;
                     context = initial_context;
                   })
        in
        {
          state with
          streams =
            Streams.stream_transition state.streams id stream_state
            |> Streams.update_last_local_stream id;
        }

let get_body_writers state =
  Streams.body_writers (`Client state.State.streams)
  |> List.map (fun (f, id) () ->
         let handler = body_writer_handler f id in
         fun state -> handler state)

let connect :
    'c.
    ?config:Settings.t ->
    request_writer:'c Request.request_writer ->
    _ Eio.Resource.t ->
    'c iteration =
 fun ?(config = Settings.default) ~request_writer socket ->
  let frame_handler =
    frame_handler ~process_complete_headers ~process_data_frame
  in

  let user_events_handlers state =
    (match state.State.shutdown with
    | false -> request_writer_handler request_writer :: get_body_writers state
    | true -> get_body_writers state)
    |> List.map (fun f () ->
           let handler = f () in
           fun state -> step InProgress (handler state))
  in

  let initial_writer = Writer.create Settings.default.max_frame_size in
  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in

  Writer.write_connection_preface initial_writer;
  Writer.write_settings initial_writer user_settings;

  let initial_state_result =
    match Writer.write initial_writer socket with
    | Ok () -> (
        match process_preface_settings ~socket ~receive_buffer () with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial ~user_settings ~peer_settings ~writer,
                rest_to_parse ))
    | Error exn -> Error (Exn exn)
  in

  start ~frame_handler ~receive_buffer ~initial_state_result
    ~user_events_handlers socket
