open Runtime

type state = Streams.server_peer State.t
type interation = Types.iteration
type stream_state = Streams.server_peer Streams.Stream.state

let process_request :
    Reqd.handler ->
    state ->
    Header.Pseudo.request_pseudo ->
    bool ->
    Header.t list ->
    stream_state ->
    Stream_identifier.t ->
    state step =
 fun request_handler state pseudo end_stream header_list (State stream_state)
     stream_id ->
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  match stream_state with
  | Idle ->
      let open_streams = Streams.count_open state.streams in
      if open_streams < Int32.to_int state.local_settings.max_concurrent_streams
      then
        let reqd =
          {
            Reqd.meth = Method.of_string pseudo.meth;
            path = pseudo.path;
            authority = pseudo.authority;
            scheme = pseudo.scheme;
            headers = Header.filter_pseudo header_list;
          }
        in

        let (ReqdHandle
               {
                 body_reader = reader;
                 response_writer;
                 error_handler;
                 on_close;
                 context;
               }) =
          request_handler reqd
        in

        let new_stream_state : stream_state =
          if end_stream then
            State
              (HalfClosed
                 (Remote
                    {
                      writers = WritingResponse response_writer;
                      error_handler;
                      on_close;
                      context;
                    }))
          else
            State
              (Open
                 {
                   readers = BodyReader reader;
                   writers = WritingResponse response_writer;
                   error_handler;
                   on_close;
                   context;
                 })
        in

        step InProgress
          {
            state with
            streams =
              Streams.stream_transition state.streams stream_id new_stream_state;
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
        "HEADERS received on closed stream"

let process_complete_headers :
    Reqd.handler -> state -> Frame.frame_header -> Header.t list -> state step =
 fun request_handler state { Frame.flags; stream_id; _ } header_list ->
  let connection_error = step_connection_error state in
  let stream_error = step_stream_error state in
  let end_stream = Flags.test_end_stream flags in
  let pseudo_validation = Header.Pseudo.validate_request header_list in

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
      | Reserved _ -> stream_error stream_id Error_code.StreamClosed
      | Idle -> stream_error stream_id Error_code.ProtocolError
      | Closed | HalfClosed (Remote _) ->
          connection_error Error_code.StreamClosed
            "HEADERS received on a closed stream")
  | end_stream, Valid pseudo ->
      process_request request_handler state pseudo end_stream header_list
        (State stream_state) stream_id

let make_response_writer_handler :
    Streams.server_peer Streams.Stream.t ->
    Stream_identifier.t ->
    (unit -> state -> state) option =
 fun stream id ->
  let (State stream_state) = stream.state in
  match stream_state with
  | Open
      ({
         writers = WritingResponse response_writer;
         readers;
         error_handler;
         on_close;
         context;
       } as state') ->
      Some
        (fun () ->
          let open Writer in
          let response = response_writer () in

          fun (state : state) ->
            write_headers_response state.writer state.hpack_encoder id response;
            match response with
            | `Final { body_writer = Some body_writer; _ } ->
                write_window_update state.writer id
                  Flow_control.WindowSize.initial_increment;
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams id
                      (State
                         (Open { state' with writers = BodyWriter body_writer }));
                }
            | `Final { body_writer = None; _ } ->
                write_window_update state.writer id
                  Flow_control.WindowSize.initial_increment;
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams id
                      (State
                         (HalfClosed
                            (Local { readers; error_handler; on_close; context })));
                }
            | `Interim _ -> state)
  | HalfClosed
      (Remote
         ({ writers = WritingResponse response_writer; on_close; context; _ } as
          state')) ->
      Some
        (fun () ->
          let open Writer in
          let response = response_writer () in

          fun (state : state) ->
            write_headers_response state.writer state.hpack_encoder id response;
            match response with
            | `Final { body_writer = Some body_writer; _ } ->
                write_window_update state.writer id
                  Flow_control.WindowSize.initial_increment;
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams id
                      (State
                         (HalfClosed
                            (Remote
                               { state' with writers = BodyWriter body_writer })));
                }
            | `Final { body_writer = None; _ } ->
                write_window_update state.writer id
                  Flow_control.WindowSize.initial_increment;
                on_close context;
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams id (State Closed);
                }
            | `Interim _ -> state)
  | _ -> None

let get_response_writers : state -> (unit -> state -> state) list =
 fun state ->
  Streams.StreamMap.fold
    (fun id stream acc ->
      match make_response_writer_handler stream id with
      | Some event -> event :: acc
      | None -> acc)
    state.streams.map []

let connection_handler :
    'c.
    ?config:Settings.t ->
    ?goaway_writer:(unit -> unit) ->
    error_handler:(Error.connection_error -> unit) ->
    Reqd.handler ->
    _ Eio.Resource.t ->
    _ =
 fun ?(config = Settings.default) ?goaway_writer ~error_handler request_handler
     socket _ ->
  let frame_handler =
    frame_handler
      ~process_complete_headers:(process_complete_headers request_handler)
  in

  let user_events_handlers state =
    let writers = List.concat [ get_response_writers state ] in
    (match (state.shutdown, goaway_writer) with
    | true, _ | _, None -> writers
    | false, Some f -> user_goaway_handler ~f :: writers)
    |> List.map map_event
  in

  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let mstring_len = String.length Frame.connection_preface in

  let initial_state_result =
    Eio.Flow.read_exact socket (Cstruct.sub receive_buffer 0 mstring_len);

    match Parse.magic_parse receive_buffer.buffer ~off:0 ~len:mstring_len with
    | Error _ as err -> err
    | Ok _ -> (
        match
          process_preface_settings ~socket ~receive_buffer ~user_settings:config
            ()
        with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial ~user_settings:config ~peer_settings ~writer,
                rest_to_parse ))
  in

  let initial_step =
    start ~receive_buffer ~frame_handler ~initial_state_result
      ~user_events_handlers socket
  in

  let rec loop : interation -> unit =
   fun step ->
    match step with
    | { state = End; _ } -> ()
    | { state = Error err; _ } -> error_handler err
    | { state = InProgress next; _ } -> loop (next ())
  in

  loop initial_step
