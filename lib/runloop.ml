open Eio

let start :
    'a 'b 'c.
    initial_state_result:
      (('a, 'b, 'c) State.t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> ('a, 'b, 'c) State.t -> ('a, 'b, 'c) Runtime.step) ->
    receive_buffer:Cstruct.t ->
    user_functions_handlers:
      (('a, 'b, 'c) State.t ->
      (unit -> ('a, 'b, 'c) State.t -> ('a, 'b, 'c) State.t) list) ->
    debug:bool ->
    _ Eio.Resource.t ->
    ('a, 'b, 'c) Runtime.step
    * (('a, 'b, 'c) State.t -> ('a, 'b, 'c) Runtime.step) =
 fun ~initial_state_result ~frame_handler ~receive_buffer
     ~user_functions_handlers ~debug socket ->
  let read_loop off =
    let read_bytes =
      try
        Ok
          (Flow.single_read socket
             (Cstruct.sub receive_buffer off
                (Cstruct.length receive_buffer - off)))
      with
      (* NOTE: we might want to do other error handling for specific exceptions *)
      | Eio.Cancel.Cancelled _ as e -> raise e
      | End_of_file as exn -> Error exn
      | Eio.Io (Eio.Net.(E (Connection_reset _)), _) as exn -> Error exn
      | exn -> Error exn
    in
    fun state ->
      match read_bytes with
      | Error exn ->
          let err : Error.connection_error = Exn exn in
          Runtime.handle_connection_error ~state err;
          Runtime.ConnectionError err
      | Ok read_bytes -> (
          let consumed, next_state =
            Runtime.read_io ~debug ~frame_handler state
              (Cstruct.sub receive_buffer 0 (read_bytes + off))
          in
          let unconsumed = read_bytes + off - consumed in
          Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
          match next_state with
          | NextState next_state ->
              NextState { next_state with read_off = unconsumed }
          | other -> other)
  in

  let flush_write : ('a, 'b, 'c) State.t -> ('a, 'b, 'c) Runtime.step =
   fun state ->
    match Writer.write state.State.writer socket with
    | Ok () ->
        if state.shutdown && Streams.all_closed state.streams then (
          Faraday.close (State.do_flush state).writer.faraday;
          Runtime.End)
        else NextState (State.do_flush state)
    | Error err ->
        Runtime.handle_connection_error ~state err;
        Faraday.close state.writer.faraday;
        ConnectionError err
  in

  let operations state =
    let base_op () = read_loop state.State.read_off in

    let opt_functions =
      user_functions_handlers state
      |> List.map (fun f () ->
             let handler = f () in
             fun state -> flush_write (handler state))
    in

    base_op :: opt_functions
  in

  let combine x y =
   fun step ->
    match x step with
    | Runtime.NextState new_state -> y new_state
    | other -> other
  in

  let state_to_step : ('a, 'b, 'c) State.t -> ('a, 'b, 'c) Runtime.step =
   fun state ->
    let close_faraday () = Faraday.close state.State.writer.faraday in

    match (Fiber.any ~combine (operations state)) state with
    | (ConnectionError _ as res) | (End as res) ->
        close_faraday ();
        res
    | step -> step
  in

  ( (match initial_state_result with
    | Error err ->
        Runtime.handle_connection_error err;
        ConnectionError err
    | Ok (initial_state, rest_to_parse) ->
        if Cstruct.length rest_to_parse > 0 then
          match
            Runtime.read_io ~debug ~frame_handler initial_state rest_to_parse
          with
          | _, (End as res) | _, (ConnectionError _ as res) -> res
          | consumed, NextState next_state ->
              NextState
                {
                  next_state with
                  read_off = rest_to_parse.Cstruct.len - consumed;
                }
        else state_to_step initial_state),
    state_to_step )
