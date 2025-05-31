open Runtime

type state = Streams.client_peer State.t
type iteration = Types.iteration
type 'context stream_state = Streams.client_peer Streams.Stream.state

let process_data_frame :
    state -> Frame.frame_header -> Bigstringaf.t -> state step =
 fun (state : state) { Frame.flags; stream_id; _ } bs ->
  let open Writer in
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in

  let (State
         (stream_state : (Streams.client_peer, _) Streams.Stream.internal_state))
      =
    Streams.state_of_id state.streams stream_id
  in

  match (stream_state, end_stream) with
  | Reserved _, _ ->
      connection_error Error_code.ProtocolError
        "DATA frame received on reserved stream"
  | Closed, _ | Idle, _ | HalfClosed (Remote _), _ ->
      connection_error Error_code.StreamClosed
        "DATA frame received on closed stream!"
  | Open { readers = AwaitingResponse _; _ }, _
  | HalfClosed (Local { readers = AwaitingResponse _; _ }), _ ->
      stream_error stream_id Error_code.ProtocolError
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

let process_complete_headers :
    state -> Frame.frame_header -> Header.t list -> state step =
 fun state { Frame.flags; stream_id; _ } header_list ->
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in
  let pseudo_validation = Header.Pseudo.validate_response header_list in

  let (State stream_state) = Streams.state_of_id state.streams stream_id in

  match (end_stream, pseudo_validation) with
  | _, Invalid | false, No_pseudo ->
      stream_error stream_id Error_code.ProtocolError
  | true, No_pseudo -> (
      match stream_state with
      | Open
          {
            readers = BodyReader reader;
            writers;
            error_handler;
            on_close;
            context;
          } ->
          let new_context = reader context (`End header_list) in
          step InProgress
            {
              state with
              streams =
                Streams.stream_transition state.streams stream_id
                  (State
                     (HalfClosed
                        (Remote
                           {
                             writers;
                             error_handler;
                             on_close;
                             context = new_context;
                           })));
            }
      | HalfClosed (Local { readers = BodyReader reader; on_close; context; _ })
        ->
          let new_context = reader context (`End header_list) in

          let streams =
            Streams.(stream_transition state.streams stream_id (State Closed))
          in
          on_close new_context;
          step InProgress { state with streams }
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
      | ( Open
            ({ readers = AwaitingResponse response_handler; context; _ } as
             state'),
          `Interim _ ) ->
          let _body_reader, context = response_handler context response in

          let streams =
            Streams.stream_transition state.streams stream_id
              (State (Open { state' with context }))
          in

          step InProgress { state with streams }
      | ( HalfClosed
            (Local
               ({ readers = AwaitingResponse response_handler; context; _ } as
                state')),
          `Interim _ ) ->
          let _body_reader, context = response_handler context response in

          let streams =
            Streams.stream_transition state.streams stream_id
              (State (HalfClosed (Local { state' with context })))
          in

          step InProgress { state with streams }
      | ( Open
            {
              readers = AwaitingResponse response_handler;
              writers = body_writer;
              error_handler;
              on_close;
              context;
            },
          `Final _ ) ->
          let body_reader, context = response_handler context response in

          let new_stream_state : _ stream_state =
            match (body_reader, end_stream) with
            | None, _ ->
                Writer.write_rst_stream state.writer stream_id NoError;
                on_close context;
                State Closed
            | Some _, true ->
                State
                  (HalfClosed
                     (Remote
                        {
                          writers = body_writer;
                          error_handler;
                          on_close;
                          context;
                        }))
            | Some body_reader, false ->
                State
                  (Open
                     {
                       readers = BodyReader body_reader;
                       writers = body_writer;
                       error_handler;
                       on_close;
                       context;
                     })
          in

          step InProgress
            {
              state with
              streams =
                Streams.stream_transition state.streams stream_id
                  new_stream_state;
            }
      | ( HalfClosed
            (Local
               {
                 readers = AwaitingResponse response_handler;
                 error_handler;
                 context;
                 on_close;
               }),
          `Final _ ) ->
          let body_reader, context = response_handler context response in

          let new_stream_state : _ stream_state =
            match (end_stream, body_reader) with
            | false, None ->
                Writer.write_rst_stream state.writer stream_id NoError;
                on_close context;
                State Closed
            | false, Some body_reader ->
                State
                  (HalfClosed
                     (Local
                        {
                          readers = BodyReader body_reader;
                          error_handler;
                          on_close;
                          context;
                        }))
            | true, _ ->
                on_close context;
                State Closed
          in
          let streams =
            Streams.stream_transition state.streams stream_id new_stream_state
          in
          step InProgress { state with streams }
      | Open { readers = BodyReader _; _ }, _
      | HalfClosed (Local { readers = BodyReader _; _ }), _ ->
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

  fun (state : state) ->
    match req_opt with
    | None ->
        Writer.write_goaway state.writer state.streams.last_peer_stream
          Error_code.NoError;
        let new_state = { state with shutdown = true } in
        new_state
    | Some
        (Request.Request
           {
             response_handler;
             body_writer;
             error_handler;
             initial_context;
             on_close;
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
              State
                (Open
                   {
                     readers = AwaitingResponse response_handler;
                     writers = BodyWriter body_writer;
                     error_handler;
                     context = initial_context;
                     on_close;
                   })
          | None ->
              State
                (HalfClosed
                   (Local
                      {
                        readers = AwaitingResponse response_handler;
                        error_handler;
                        context = initial_context;
                        on_close;
                      }))
        in
        {
          state with
          streams =
            Streams.stream_transition state.streams id stream_state
            |> Streams.update_last_local_stream id;
        }

let get_body_writers : state -> (unit -> state -> state) list =
 fun state ->
  Streams.StreamMap.fold
    (fun id stream acc ->
      match make_body_writer_event stream id with
      | Some event -> event :: acc
      | None -> acc)
    state.streams.map []

let connect :
    'c.
    ?config:Settings.t ->
    request_writer:Request.request_writer ->
    _ Eio.Resource.t ->
    iteration =
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
