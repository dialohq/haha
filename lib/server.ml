open Runtime
open Types

type iter_input = Shutdown
type state = Streams.server_peer State.t
type interation = iter_input Types.iteration

let process_complete_headers :
    Reqd.handler -> state -> Frame.frame_header -> Headers.t -> state step =
 fun request_handler state { Frame.flags; stream_id; _ } headers ->
  let stream_error = step_stream_error state in
  let pseudo_validation = Headers.Pseudo.validate headers in

  match (Flags.test_end_stream flags, pseudo_validation) with
  | _, Invalid _ | false, NotPresent | _, Valid (Response _) ->
      stream_error stream_id Error_code.ProtocolError
  | true, NotPresent -> (
      match
        Streams.receive_trailers ~writer:state.writer ~headers stream_id
          state.streams
      with
      | Error err -> step (ConnectionError err) state
      | Ok streams -> step InProgress { state with streams })
  | end_stream, Valid (Request pseudo) -> (
      match
        Streams.receive_request ~writer:state.writer ~request_handler ~pseudo
          ~end_stream
          ~headers:(Headers.filter_out_pseudo headers)
          ~max_streams:state.local_settings.max_concurrent_streams stream_id
          state.streams
      with
      | Error err -> step (ConnectionError err) state
      | Ok streams -> step InProgress { state with streams })

let user_goaway_handler ~f =
 fun () ->
  f ();
  fun state ->
    Writer.write_goaway state.State.writer
      (Streams.last_peer_stream state.streams)
      Error_code.NoError;
    { iter_result = InProgress; state = { state with shutdown = true } }

let get_response_writers : state -> (unit -> state -> state step) list =
 fun { writer; streams; _ } ->
  Streams.response_writers_transitions ~writer streams
  |> map_streams_transitions

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
              ( State.initial_server ~user_settings:config ~peer_settings ~writer,
                rest_to_parse ))
  in

  let input_handler = fun s _ -> s in

  let extra_events_handlers state =
    let writers = List.concat [ get_response_writers state ] in
    match (state.shutdown, goaway_writer) with
    | true, _ | _, None -> writers
    | false, Some f -> user_goaway_handler ~f :: writers
  in

  let initial_step =
    start ~extra_events_handlers ~receive_buffer ~frame_handler
      ~initial_state_result ~input_handler socket
  in

  let rec loop : interation -> unit =
   fun step ->
    match step with
    | { state = End; _ } -> ()
    | { state = Error err; _ } -> error_handler err
    | { state = InProgress next; _ } -> loop (next [])
  in

  loop initial_step
