open State

type state = State.t
type stream_state = Streams.Stream.state

let run ~(error_handler : Error.t -> unit)
    ~(request_writer : Request.request_writer) (config : Settings.t) socket =
  let open Serialize in
  let state = State.initial in

  write_connection_preface state.faraday;
  write_settings state.faraday config;

  (match Faraday.operation state.faraday with
  | `Close | `Yield -> ()
  | `Writev bs_list ->
      let written, cs_list =
        List.fold_left
          (fun ((to_write, cs_list) : int * Cstruct.t list)
               (bs_iovec : Bigstringaf.t Faraday.iovec) ->
            ( bs_iovec.len + to_write,
              Cstruct.of_bigarray ~off:bs_iovec.off ~len:bs_iovec.len
                bs_iovec.buffer
              :: cs_list ))
          (0, []) bs_list
      in
      Eio.Flow.write socket (List.rev cs_list);
      Faraday.shift state.faraday written);

  let handle_preface (state : state) (recvd_settings : Settings.settings_list) :
      state option =
    let open Serialize in
    write_settings_ack state.faraday;
    write_window_update state.faraday Stream_identifier.connection
      Flow_control.WindowSize.initial_increment;
    let frames_state = initial_frame_state recvd_settings config in

    Printf.printf "Connection fully established\n%!";

    Some { state with phase = Frames frames_state }
  in

  let process_complete_headers
      (module RuntimeOperations : Runtime.RUNTIMEOPERATIONS)
      { Frame.flags; stream_id; _ } header_list =
    let open RuntimeOperations in
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Headers.Pseudo.validate_response header_list in

    let stream_state = Streams.state_of_id frames_state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        Printf.printf "Received some HEADERS, trailers\n%!";
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
        (* TODO: should expose trailers to API - body_reader could take some `Data of cs and `End of data option * trailers variants *)
        match stream_state with
        | Open (_, writers) ->
            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    (Half_closed (Remote writers));
              }
        | Half_closed (Local _) ->
            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    Closed;
              }
        | Reserved _ ->
            (* TODO: check if this is the correct error *)
            stream_error stream_id Error_code.ProtocolError
        | Idle -> stream_error stream_id Error_code.ProtocolError
        | Closed | Half_closed (Remote _) ->
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
        | Open (Responses response_handler, _), `Interim _
        | Half_closed (Local (Responses response_handler)), `Interim _ ->
            let _body_reader = response_handler response in

            next_step frames_state
        | Open (Responses response_handler, body_writer), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then Half_closed (Remote body_writer)
              else Open (Body body_reader, body_writer)
            in

            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    new_stream_state;
              }
        | Half_closed (Local (Responses response_handler)), `Final _ ->
            let body_reader = response_handler response in

            let new_stream_state : stream_state =
              if end_stream then Closed
              else Half_closed (Local (Body body_reader))
            in

            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    new_stream_state;
              }
        | Open (Body _, Body _), _ | Half_closed (Local (Body _)), _ ->
            connection_error Error_code.ProtocolError
              "unexpected multiple HEADERS responses on single stream"
        | Open (_, Responses _), _ ->
            (* TODO: ??? *)
            connection_error Error_code.InternalError ""
        | Idle, _ ->
            connection_error Error_code.ProtocolError
              "unexpected HEADERS response on idle stream"
        | Reserved _, _ ->
            connection_error Error_code.ProtocolError
              "HEADERS received on reserved stream"
        | Half_closed (Remote _), _ | Closed, _ ->
            connection_error Error_code.StreamClosed
              "HEADERS received on closed stream")
  in

  let token_handler =
    Runtime.token_handler ~process_complete_headers ~handle_preface
      ~error_handler
  in

  let read_io (state : state) (cs : Cstruct.t) : int * state option =
    match Parse.read cs state.parse_state with
    | Ok (consumed, frames, new_parse_state) ->
        let state_with_parse = { state with parse_state = new_parse_state } in

        let next_state =
          List.fold_left
            (fun state frame ->
              match state with
              | None -> None
              | Some state -> token_handler frame state)
            (Some state_with_parse) frames
        in

        (consumed, next_state)
    | Error err ->
        let next_state =
          match err with
          | Error.ConnectionError (code, msg) ->
              Runtime.handle_connection_error state code msg
          | StreamError (stream_id, code) ->
              Runtime.handle_stream_error state stream_id code
        in

        (0, next_state)
  in

  let initial_state =
    { state with phase = Preface true; parse_state = Frames None }
  in
  let default_max_frame_size = Settings.default.max_frame_size in
  Runloop.start ~request_writer ~read_io ~max_frame_size:default_max_frame_size
    ~initial_state socket
