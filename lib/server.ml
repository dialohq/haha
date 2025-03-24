open State
open Types

type state = State.t
type request_handler = Request.t -> body_reader * Response.response_writer

(* TODO: config argument could have some more user-friendly type so there is no need to look into RFC *)
let connection_handler ~(error_handler : Error.t -> unit)
    ?(goaway_writer : (unit -> unit) option) (config : Settings.t)
    (request_handler : request_handler) socket _ =
  let handle_preface state (recvd_settings : Settings.settings_list) :
      State.t option =
    let open Serialize in
    write_settings state.faraday config;
    write_settings_ack state.faraday;
    write_window_update state.faraday Stream_identifier.connection
      Flow_control.WindowSize.initial_increment;
    let frames_state = State.initial_frame_state recvd_settings config in

    Some { state with phase = Frames frames_state }
  in

  let process_complete_headers
      (module RuntimeOperations : Runtime.RUNTIMEOPERATIONS)
      { Frame.flags; stream_id; _ } header_list =
    let open RuntimeOperations in
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Headers.Pseudo.validate_request header_list in

    let stream_state = Streams.state_of_id frames_state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
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
        match stream_state with
        | Idle ->
            let request =
              {
                Request.meth = Method.of_string pseudo.meth;
                path = pseudo.path;
                authority = pseudo.authority;
                scheme = pseudo.scheme;
                headers = Headers.filter_pseudo header_list;
                body_writer = None;
                response_handler = None;
              }
            in

            let reader, response_writer = request_handler request in

            next_step
              {
                frames_state with
                streams =
                  Streams.stream_transition frames_state.streams stream_id
                    (if end_stream then
                       Half_closed (Remote (Responses response_writer))
                     else Open (Body reader, Responses response_writer));
              }
        | Open _ | Half_closed (Local _) ->
            stream_error stream_id Error_code.ProtocolError
        | Reserved _ ->
            connection_error Error_code.ProtocolError
              "HEADERS received on reserved stream"
        | Half_closed (Remote _) | Closed ->
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

  let default_max_frame = Settings.default.max_frame_size in
  Runloop.start ~max_frame_size:default_max_frame ~initial_state:State.initial
    ~read_io ?await_user_goaway:goaway_writer socket
