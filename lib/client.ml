open Writer

type state = (Streams.client_readers, Streams.client_writer) State.t

type stream_state =
  (Streams.client_readers, Streams.client_writer) Streams.Stream.state

let pp_hum_state =
  State.pp_hum Streams.pp_hum_client_readers Streams.pp_hum_client_writer

let run ?(debug = false) ~(error_handler : Error.t -> unit)
    ~(request_writer : Request.request_writer) (config : Settings.t) socket =
  let semaphore = Eio.Semaphore.make 1 in

  let process_data_frame (state : state) stream_error connection_error next_step
      no_error_close { Frame.flags; stream_id; _ } bs =
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
        if debug then
          Printf.printf
            "Received DATA frame on HalfClosed (Local (AwaitingResponse)) \
             stream - DATA before response";
        stream_error stream_id Error_code.ProtocolError
    | Open (BodyStream reader, writers), true ->
        (* if debug then Printf.printf "Reader acquiring semaphore\n%!"; *)
        (* Eio.Semaphore.acquire semaphore; *)
        (* if debug then Printf.printf "Reader starting\n%!"; *)
        if debug then Printf.printf "on_data End %li\n%!" stream_id;
        if debug then Printf.printf "on_data fork before End %li\n%!" stream_id;
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        if debug then Printf.printf "on_data fork after End %li\n%!" stream_id;

        (* if debug then Printf.printf "Reader releasing semaphore\n%!"; *)
        (* Eio.Semaphore.release semaphore; *)
        next_step
          {
            state with
            streams =
              Streams.stream_transition state.streams stream_id
                (HalfClosed (Remote writers));
          }
    | Open (BodyStream reader, _), false ->
        (* if debug then Printf.printf "Reader acquiring semaphore\n%!"; *)
        (* Eio.Semaphore.acquire semaphore; *)
        (* if debug then Printf.printf "Reader starting\n%!"; *)
        if debug then Printf.printf "on_data %li\n%!" stream_id;
        if debug then Printf.printf "on_data fork before %li\n%!" stream_id;
        reader (`Data (Cstruct.of_bigarray bs));
        if debug then Printf.printf "on_data fork after %li\n%!" stream_id;

        (* if debug then Printf.printf "Reader releasing semaphore\n%!"; *)
        (* Eio.Semaphore.release semaphore; *)
        next_step
          {
            state with
            streams = Streams.update_last_stream state.streams stream_id;
          }
    | HalfClosed (Local (BodyStream reader)), true ->
        (* if debug then Printf.printf "Reader acquiring semaphore\n%!"; *)
        (* Eio.Semaphore.acquire semaphore; *)
        (* if debug then Printf.printf "Reader starting\n%!"; *)
        if debug then Printf.printf "on_data End %li\n%!" stream_id;
        if debug then Printf.printf "on_data fork before End %li\n%!" stream_id;
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        if debug then Printf.printf "on_data fork after End %li\n%!" stream_id;

        (* if debug then Printf.printf "Reader releasing semaphore\n%!"; *)
        (* Eio.Semaphore.release semaphore; *)
        let new_streams =
          Streams.stream_transition state.streams stream_id Closed
        in

        if
          state.shutdown
          && Streams.all_closed ~last_stream_id:state.streams.last_client_stream
               new_streams
        then no_error_close ()
        else next_step { state with streams = new_streams }
    | HalfClosed (Local (BodyStream reader)), false ->
        (* if debug then Printf.printf "Reader acquiring semaphore\n%!"; *)
        (* Eio.Semaphore.acquire semaphore; *)
        (* if debug then Printf.printf "Reader starting\n%!"; *)
        if debug then Printf.printf "on_data %li\n%!" stream_id;
        if debug then Printf.printf "on_data fork before %li\n%!" stream_id;
        reader (`Data (Cstruct.of_bigarray bs));
        if debug then Printf.printf "on_data fork after %li\n%!" stream_id;

        (* if debug then Printf.printf "Reader releasing semaphore\n%!"; *)
        (* Eio.Semaphore.release semaphore; *)
        next_step
          {
            state with
            streams = Streams.update_last_stream state.streams stream_id;
          }
  in

  let process_complete_headers (state : state) stream_error connection_error
      next_step { Frame.flags; stream_id; _ } header_list =
    let new_state =
      let end_stream = Flags.test_end_stream flags in
      let pseudo_validation = Headers.Pseudo.validate_response header_list in

      let stream_state = Streams.state_of_id state.streams stream_id in

      match (end_stream, pseudo_validation) with
      | _, Invalid | false, No_pseudo ->
          if debug then
            Printf.printf
              "HEADERS %li - Invalid pseudo and END_STREAM combination\n%!"
              stream_id;
          stream_error stream_id Error_code.ProtocolError
      | true, No_pseudo -> (
          if debug then
            Format.printf
              "HEADERS %li, trailers - no pseudo, END_STREAM@.Current \
               state:@.%a@."
              stream_id pp_hum_state state;
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
              next_step
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams stream_id Closed;
                }
          | Open (AwaitingResponse _, _)
          | HalfClosed (Local (AwaitingResponse _)) ->
              connection_error Error_code.ProtocolError
                (Format.sprintf
                   "received first HEADERS in stream %li with no pseudo-headers"
                   stream_id)
          | Reserved _ -> stream_error stream_id Error_code.StreamClosed
          | Idle ->
              if debug then
                Printf.printf "Received no_pseudo HEADERS on Idle stream\n%!";
              stream_error stream_id Error_code.ProtocolError
          | Closed | HalfClosed (Remote _) ->
              connection_error Error_code.StreamClosed
                "HEADERS received on a closed stream")
      | end_stream, Valid pseudo -> (
          if debug then
            Format.printf
              "HEADERS %li - with pseudo, END_STREAM: %b@.Current state:@.%a@."
              stream_id end_stream pp_hum_state state;
          let headers = Headers.filter_pseudo header_list in
          let response : Response.t =
            match Status.of_code pseudo.status with
            | #Status.informational as status -> `Interim { status; headers }
            | status -> `Final { status; headers; body_writer = None }
          in
          match (stream_state, response) with
          | Open (AwaitingResponse response_handler, _), `Interim _
          | HalfClosed (Local (AwaitingResponse response_handler)), `Interim _
            ->
              (* if debug then *)
              (*   Printf.printf "Response handler acquiring semaphore\n%!"; *)
              (* Eio.Semaphore.acquire semaphore; *)
              (* if debug then Printf.printf "Response handler starting\n%!"; *)
              let _body_reader = response_handler response in
              (* if debug then Printf.printf "Response releasing semaphore\n%!"; *)
              (* Eio.Semaphore.release semaphore; *)

              next_step state
          | Open (AwaitingResponse response_handler, body_writer), `Final _ ->
              (* if debug then *)
              (*   Printf.printf "Response handler acquiring semaphore\n%!"; *)
              (* Eio.Semaphore.acquire semaphore; *)
              (* if debug then Printf.printf "Response handler starting\n%!"; *)
              let body_reader = response_handler response in
              (* if debug then Printf.printf "Response releasing semaphore\n%!"; *)
              (* Eio.Semaphore.release semaphore; *)

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
              (* if debug then *)
              (*   Printf.printf "Response handler acquiring semaphore\n%!"; *)
              (* Eio.Semaphore.acquire semaphore; *)
              (* if debug then Printf.printf "Response handler starting\n%!"; *)
              let body_reader = response_handler response in
              (* if debug then Printf.printf "Response releasing semaphore\n%!"; *)
              (* Eio.Semaphore.release semaphore; *)

              let new_stream_state : stream_state =
                if end_stream then Closed
                else HalfClosed (Local (BodyStream body_reader))
              in

              next_step
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams stream_id
                      new_stream_state;
                }
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

    (if debug then
       match new_state with
       | Some new_state ->
           Format.printf "Transitioning to a new state:@.%a@." pp_hum_state
             new_state
       | None -> Printf.printf "Transitioning to None\n%!");
    new_state
  in

  let frame_handler =
    Runtime.frame_handler ~process_complete_headers ~process_data_frame
      ~error_handler ~peer:`Client
  in

  let request_writer_handler (state : state) =
    let request = request_writer () in

    let id = Streams.get_next_id state.streams `Client in
    Printf.printf "Creating request with id %li\n%!" id;
    writer_request_headers state.writer state.hpack_encoder id request;
    write_window_update state.writer id
      Flow_control.WindowSize.initial_increment;
    let response_handler = Option.get request.response_handler in
    let stream_state : stream_state =
      match request.body_writer with
      | Some body_writer ->
          Streams.Stream.Open (AwaitingResponse response_handler, body_writer)
      | None -> HalfClosed (Local (AwaitingResponse response_handler))
    in
    Printf.printf "Processed request dupa, id: %li\n%!" id;
    {
      state with
      streams = Streams.stream_transition state.streams id stream_state;
    }
  in

  let get_body_writers frames_state =
    Streams.body_writers (`Client frames_state.State.streams)
  in

  let combine_states =
    State.combine ~combine_streams:Streams.combine_client_streams
  in

  (* TODO: we could create so scoped function here for the initial writer to be sure it is freed *)
  let initial_writer = create Settings.default.max_frame_size in
  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in

  write_connection_preface initial_writer;
  write_settings initial_writer user_settings;

  write initial_writer socket;

  let initial_state_result =
    match Runtime.parse_preface_settings ~socket ~receive_buffer () with
    | Error _ as err -> err
    | Ok (peer_settings, rest_to_parse, writer) ->
        Ok (State.initial ~user_settings ~peer_settings ~writer, rest_to_parse)
  in

  Runloop.start ~request_writer_handler ~frame_handler ~receive_buffer
    ~get_body_writers ~initial_state_result ~combine_states ~pp_hum_state
    ~semaphore ~debug socket
