open Types

type state = Streams.((server_reader, server_writers) State.t)
type stream_state = Streams.((server_reader, server_writers) Stream.state)
type request_handler = Request.t -> body_reader * Response.response_writer

(* TODO: config argument could have some more user-friendly type so there is no need to look into RFC *)
let connection_handler ~(error_handler : Error.t -> unit)
    ?(goaway_writer : (unit -> unit) option) (config : Settings.t)
    (request_handler : request_handler) socket _ =
  let process_data_frame (state : state) stream_error connection_error next_step
      no_error_close { Frame.stream_id; flags; _ } bs =
    let end_stream = Flags.test_end_stream flags in
    match (Streams.state_of_id state.streams stream_id, end_stream) with
    | Idle, _ | Half_closed (Remote _), _ ->
        stream_error stream_id Error_code.StreamClosed
    | Reserved _, _ ->
        connection_error Error_code.ProtocolError
          "DATA frame received on reserved stream"
    | Closed, _ ->
        connection_error Error_code.StreamClosed
          "DATA frame received on closed stream!"
    | Open (reader, writers), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        next_step
          {
            state with
            streams =
              Streams.stream_transition state.streams stream_id
                (Half_closed (Remote writers));
          }
    | Open (reader, _), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            state with
            streams = Streams.update_last_stream state.streams stream_id;
          }
    | Half_closed (Local reader), true ->
        reader (`End (Some (Cstruct.of_bigarray bs), []));
        let new_streams =
          Streams.stream_transition state.streams stream_id Closed
        in

        if
          state.shutdown
          && Streams.all_closed ~last_stream_id:state.streams.last_client_stream
               new_streams
        then no_error_close ()
        else next_step { state with streams = new_streams }
    | Half_closed (Local reader), false ->
        reader (`Data (Cstruct.of_bigarray bs));
        next_step
          {
            state with
            streams = Streams.update_last_stream state.streams stream_id;
          }
  in

  let process_complete_headers (state : state) stream_error connection_error
      next_step { Frame.flags; stream_id; _ } header_list =
    let end_stream = Flags.test_end_stream flags in
    let pseudo_validation = Headers.Pseudo.validate_request header_list in

    let stream_state = Streams.state_of_id state.streams stream_id in

    match (end_stream, pseudo_validation) with
    | _, Invalid | false, No_pseudo ->
        stream_error stream_id Error_code.ProtocolError
    | true, No_pseudo -> (
        match stream_state with
        | Open (reader, writers) ->
            reader (`End (None, header_list));
            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id
                    (Half_closed (Remote writers));
              }
        | Half_closed (Local reader) ->
            reader (`End (None, header_list));
            next_step
              {
                state with
                streams =
                  Streams.stream_transition state.streams stream_id Closed;
              }
        | Reserved _ -> stream_error stream_id Error_code.StreamClosed
        | Idle -> stream_error stream_id Error_code.ProtocolError
        | Closed | Half_closed (Remote _) ->
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

              let new_stream_state : stream_state =
                if end_stream then
                  Half_closed (Remote (WritingResponse response_writer))
                else Open (reader, WritingResponse response_writer)
              in

              next_step
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams stream_id
                      new_stream_state;
                }
            else
              connection_error Error_code.ProtocolError
                "MAX_CONCURRENT_STREAMS setting reached"
        | Open _ | Half_closed (Local _) ->
            stream_error stream_id Error_code.ProtocolError
        | Reserved _ ->
            connection_error Error_code.ProtocolError
              "HEADERS received on reserved stream"
        | Half_closed (Remote _) | Closed ->
            connection_error Error_code.StreamClosed
              "HEADERS received on closed stream")
  in

  let frame_handler =
    Runtime.frame_handler ~process_complete_headers ~process_data_frame
      ~error_handler ~peer:`Server
  in

  let response_writer_handler (state : state) response_writer reader_opt id =
    let open Writer in
    let response = response_writer () in

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
          | Some reader -> Half_closed (Local reader)
        in
        {
          state with
          streams = Streams.stream_transition state.streams id new_stream_state;
        }
    | `Interim _ -> state
  in
  let get_response_writers state =
    let response_writers = Streams.response_writers state.State.streams in

    List.map
      (fun (response_writer, reader_opt, id) () ->
        response_writer_handler state response_writer reader_opt id)
      response_writers
  in
  let get_body_writers state =
    Streams.body_writers (`Server state.State.streams)
  in

  let combine_states s1 s2 =
    {
      s1 with
      State.streams =
        Streams.combine_after_response s1.State.streams s2.State.streams;
    }
  in

  let receive_buffer = Cstruct.create (9 + config.max_frame_size) in
  let user_settings = config in
  let mstring_len = String.length Frame.connection_preface in

  let initial_state_result =
    Eio.Flow.read_exact socket (Cstruct.sub receive_buffer 0 mstring_len);

    match Parse.magic_parse receive_buffer.buffer ~off:0 ~len:mstring_len with
    | Error _ as err -> err
    | Ok _ -> (
        match
          Runtime.parse_preface_settings ~socket ~receive_buffer ~user_settings
            0 0 0 None
        with
        | Error _ as err -> err
        | Ok (peer_settings, rest_to_parse, writer) ->
            Ok
              ( State.initial ~user_settings ~peer_settings ~writer,
                rest_to_parse ))
  in

  Runloop.start ~receive_buffer ~frame_handler ~get_body_writers
    ~get_response_writers ~combine_states ~initial_state_result
    ?await_user_goaway:goaway_writer socket
