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

(* TODO: config argument could have some more user-friendly type so there is no need to look into RFC *)
let connection_handler :
    'c.
    ?debug:bool ->
    ?config:Settings.t ->
    ?goaway_writer:(unit -> unit) ->
    error_handler:(Error.connection_error -> unit) ->
    (Reqd.t -> 'c Reqd.handler) ->
    _ Eio.Resource.t ->
    _ =
 fun ?(debug = false) ?(config = Settings.default) ?goaway_writer ~error_handler
     request_handler socket _ ->
  let process_data_frame (state : _ state) stream_error connection_error
      { Frame.stream_id; flags; _ } bs : _ Runtime.step =
    let open Writer in
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
    | Open { readers; writers; error_handler; context }, true ->
        let new_context =
          readers context (`End (Some (Cstruct.of_bigarray bs), []))
        in
        NextState
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
                  (write_window_update state.writer Stream_identifier.connection)
                state.flow
                (Bigstringaf.length bs |> Int32.of_int);
          }
    | Open { readers; context; _ }, false ->
        let new_context = readers context (`Data (Cstruct.of_bigarray bs)) in

        let streams =
          (if Stream_identifier.is_server stream_id then state.streams
           else Streams.update_last_peer_stream state.streams stream_id)
          |> Streams.update_flow_on_data
               ~send_update:(write_window_update state.writer stream_id)
               stream_id
               (Bigstringaf.length bs |> Int32.of_int)
          |> Streams.update_context stream_id new_context
        in
        NextState
          {
            state with
            streams;
            flow =
              Flow_control.receive_data
                ~send_update:
                  (write_window_update state.writer Stream_identifier.connection)
                state.flow
                (Bigstringaf.length bs |> Int32.of_int);
          }
    | HalfClosed (Local { readers; context; _ }), true ->
        let new_context =
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
        NextState
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
    | HalfClosed (Local { readers; context; _ }), false ->
        let new_context = readers context (`Data (Cstruct.of_bigarray bs)) in

        let streams =
          (if Stream_identifier.is_server stream_id then state.streams
           else Streams.update_last_peer_stream state.streams stream_id)
          |> Streams.update_flow_on_data
               ~send_update:(write_window_update state.writer stream_id)
               stream_id
               (Bigstringaf.length bs |> Int32.of_int)
          |> Streams.update_context stream_id new_context
        in
        NextState
          {
            state with
            streams;
            flow =
              Flow_control.receive_data
                ~send_update:
                  (write_window_update state.writer Stream_identifier.connection)
                state.flow
                (Bigstringaf.length bs |> Int32.of_int);
          }
  in

  let process_complete_headers (state : _ state) stream_error connection_error
      { Frame.flags; stream_id; _ } header_list : _ Runtime.step =
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Header.Pseudo.validate_request header_list in

    let stream_state = Streams.state_of_id state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
        match stream_state with
        | Open { readers; writers; error_handler; context } ->
            let new_context = readers context (`End (None, header_list)) in
            NextState
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    (HalfClosed
                       (Remote { writers; error_handler; context = new_context }));
              }
        | HalfClosed (Local { readers; context; _ }) ->
            let new_context = readers context (`End (None, header_list)) in
            let streams =
              Streams.(stream_transition state.streams stream_id Closed)
            in
            NextState
              {
                state with
                streams;
                final_contexts =
                  (stream_id, new_context) :: state.final_contexts;
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

              let readers, response_writer, error_handler, initial_context =
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

              NextState
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
  in

  let frame_handler =
    Runtime.frame_handler ~process_complete_headers ~process_data_frame
  in

  let response_writer_handler response_writer reader_opt id error_handler
      context =
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
            streams =
              Streams.stream_transition state.streams id new_stream_state;
          }
      | `Interim _ -> state
  in
  let get_response_writers state =
    let response_writers = Streams.response_writers state.State.streams in

    List.map
      (fun (response_writer, reader_opt, id, error_handler, context) () state ->
        response_writer_handler response_writer reader_opt id error_handler
          context state)
      response_writers
  in

  let get_body_writers state =
    Streams.body_writers (`Server state.State.streams)
    |> List.map (fun (f, id) () ->
           let handler = Runtime.body_writer_handler f id in
           fun state -> handler state)
  in

  let user_functions_handlers state =
    let writers =
      List.concat [ get_response_writers state; get_body_writers state ]
    in
    match (state.shutdown, goaway_writer) with
    | true, _ | _, None -> writers
    | false, Some f ->
        (fun () ->
          let handler = Runtime.user_goaway_handler ~f in
          fun state -> handler state)
        :: writers
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
          Runtime.process_preface_settings ~socket ~receive_buffer
            ~user_settings ()
        with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial ~user_settings ~peer_settings ~writer,
                rest_to_parse ))
  in

  let initial_step =
    Runtime.start ~receive_buffer ~frame_handler ~initial_state_result ~debug
      ~user_functions_handlers socket
  in

  let rec loop : _ interation -> unit =
   fun step ->
    match step with
    | { state = End; _ } -> ()
    | { state = Error err; _ } -> error_handler err
    | { state = InProgress next; _ } -> loop (next ())
  in

  loop initial_step
