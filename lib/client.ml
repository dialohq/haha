open Writer

type state = (Streams.client_readers, Streams.client_writer) State.t

type stream_state =
  (Streams.client_readers, Streams.client_writer) Streams.Stream.state

let pp_hum_state =
  State.pp_hum Streams.pp_hum_client_readers Streams.pp_hum_client_writer

let run ?(debug = false) ~(error_handler : Error.t -> unit)
    ~(request_writer : Request.request_writer) (config : Settings.t) socket =
  let process_data_frame (state : state) stream_error connection_error next_step
      { Frame.flags; stream_id; _ } bs =
    let end_stream = Flags.test_end_stream flags in
    match (Streams.state_of_id state.streams stream_id, end_stream) with
    | Reserved _, _ ->
        connection_error Error_code.ProtocolError
          "DATA frame received on reserved stream"
    | Closed, _ | Idle, _ | HalfClosed (Remote _), _ ->
        connection_error Error_code.StreamClosed
          "DATA frame received on closed stream!"
    | Open (AwaitingResponse _, _), _
    | HalfClosed (Local (AwaitingResponse _)), _ ->
        stream_error stream_id Error_code.ProtocolError
    | Open (BodyStream reader, writers), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));

        next_step
          {
            state with
            streams =
              Streams.(
                stream_transition state.streams stream_id
                  (HalfClosed (Remote writers))
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
    | Open (BodyStream reader, _), false ->
        reader (`Data (Cstruct.of_bigarray bs));

        let streams =
          (if Stream_identifier.is_client stream_id then state.streams
           else Streams.update_last_peer_stream state.streams stream_id)
          |> Streams.update_flow_on_data
               ~send_update:(write_window_update state.writer stream_id)
               stream_id
               (Bigstringaf.length bs |> Int32.of_int)
        in
        next_step
          {
            state with
            streams;
            flow =
              Flow_control.receive_data state.flow
                ~send_update:
                  (write_window_update state.writer Stream_identifier.connection)
                (Bigstringaf.length bs |> Int32.of_int);
          }
    | HalfClosed (Local (BodyStream reader)), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));

        let streams =
          Streams.(
            stream_transition state.streams stream_id Closed
            |> update_flow_on_data
                 ~send_update:(write_window_update state.writer stream_id)
                 stream_id
                 (Bigstringaf.length bs |> Int32.of_int))
        in
        next_step
          {
            state with
            streams;
            flow =
              Flow_control.receive_data state.flow
                ~send_update:
                  (write_window_update state.writer Stream_identifier.connection)
                (Bigstringaf.length bs |> Int32.of_int);
          }
    | HalfClosed (Local (BodyStream reader)), false ->
        reader (`Data (Cstruct.of_bigarray bs));

        let streams =
          (if Stream_identifier.is_client stream_id then state.streams
           else Streams.update_last_peer_stream state.streams stream_id)
          |> Streams.update_flow_on_data
               ~send_update:(write_window_update state.writer stream_id)
               stream_id
               (Bigstringaf.length bs |> Int32.of_int)
        in
        next_step
          {
            state with
            streams;
            flow =
              Flow_control.receive_data state.flow
                ~send_update:
                  (write_window_update state.writer Stream_identifier.connection)
                (Bigstringaf.length bs |> Int32.of_int);
          }
  in

  let process_complete_headers (state : state) stream_error connection_error
      next_step { Frame.flags; stream_id; _ } header_list =
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Headers.Pseudo.validate_response header_list in

    let stream_state = Streams.state_of_id state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
        match stream_state with
        | Open (BodyStream reader, writers) ->
            reader (`End (None, header_list));
            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    (HalfClosed (Remote writers));
              }
        | HalfClosed (Local (BodyStream reader)) ->
            reader (`End (None, header_list));

            let streams =
              Streams.stream_transition state.streams stream_id Closed
            in
            next_step { state with streams }
        | Open (AwaitingResponse _, _) | HalfClosed (Local (AwaitingResponse _))
          ->
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
        let headers = Headers.filter_pseudo header_list in
        let response : Response.t =
          match Status.of_code pseudo.status with
          | #Status.informational as status -> `Interim { status; headers }
          | status -> `Final { status; headers; body_writer = None }
        in
        match (stream_state, response) with
        | Open (AwaitingResponse response_handler, _), `Interim _
        | HalfClosed (Local (AwaitingResponse response_handler)), `Interim _ ->
            let _body_reader = response_handler response in

            next_step state
        | Open (AwaitingResponse response_handler, body_writer), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then HalfClosed (Remote body_writer)
              else Open (BodyStream body_reader, body_writer)
            in

            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    new_stream_state;
              }
        | HalfClosed (Local (AwaitingResponse response_handler)), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then Closed
              else HalfClosed (Local (BodyStream body_reader))
            in
            let streams =
              Streams.stream_transition state.streams stream_id new_stream_state
            in
            next_step { state with streams }
        | Open (BodyStream _, _), _ | HalfClosed (Local (BodyStream _)), _ ->
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
  in

  let frame_handler =
    Runtime.frame_handler ~process_complete_headers ~process_data_frame
      ~error_handler
  in

  let request_writer_handler () =
    let req_opt = request_writer () in

    fun (state : state) ->
      match req_opt with
      | None ->
          write_goaway state.writer state.streams.last_peer_stream
            Error_code.NoError;
          let new_state = { state with shutdown = true } in
          new_state
      | Some request ->
          let id = Streams.get_next_id state.streams `Client in
          writer_request_headers state.writer state.hpack_encoder id request;
          write_window_update state.writer id
            Flow_control.WindowSize.initial_increment;
          let response_handler = Option.get request.response_handler in
          let stream_state : stream_state =
            match request.body_writer with
            | Some body_writer ->
                Streams.Stream.Open
                  (AwaitingResponse response_handler, body_writer)
            | None -> HalfClosed (Local (AwaitingResponse response_handler))
          in
          {
            state with
            streams =
              Streams.stream_transition state.streams id stream_state
              |> Streams.update_last_local_stream id;
          }
  in

  let get_body_writers state =
    Streams.body_writers (`Client state.State.streams)
    |> List.map (fun (f, id) () ->
           let handler = Runtime.body_writer_handler ~debug f id in
           fun state -> handler state)
  in

  let user_functions_handlers state =
    match state.State.shutdown with
    | false -> request_writer_handler :: get_body_writers state
    | true -> get_body_writers state
  in

  (* TODO: we could create so scoped function here for the initial writer to be sure it is freed *)
  let initial_writer = create Settings.default.max_frame_size in
  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in

  write_connection_preface initial_writer;
  write_settings initial_writer user_settings;

  let initial_state_result =
    match write initial_writer socket with
    | Ok () -> (
        match Runtime.process_preface_settings ~socket ~receive_buffer () with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial ~user_settings ~peer_settings ~writer,
                rest_to_parse ))
    | Error msg -> Error (Error_code.ConnectError, msg)
  in

  Runloop.start ~frame_handler ~receive_buffer ~initial_state_result
    ~pp_hum_state ~debug ~user_functions_handlers ~error_handler socket
