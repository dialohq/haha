open Eio

let start :
    'a 'b.
    initial_state_result:
      (('a, 'b) State.t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> ('a, 'b) State.t -> ('a, 'b) Runtime.step) ->
    receive_buffer:Cstruct.t ->
    pp_hum_state:(Format.formatter -> ('a, 'b) State.t -> unit) ->
    user_functions_handlers:
      (('a, 'b) State.t -> (unit -> ('a, 'b) State.t -> ('a, 'b) State.t) list) ->
    debug:bool ->
    (* error_handler:(Error.connection_error -> unit) -> *)
    _ ->
    _ =
 fun ~initial_state_result ~frame_handler ~receive_buffer ~pp_hum_state:_
     ~user_functions_handlers ~debug (* ~error_handler *) socket ->
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
          (* error_handler err; *)
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

  let operations state =
    let base_op () = read_loop state.State.read_off in

    let opt_functions =
      user_functions_handlers state
      |> List.map (fun f () ->
             let handler = f () in
             fun state -> Runtime.NextState (handler state))
    in

    base_op :: opt_functions
  in

  let combine x y =
   fun step ->
    match x step with
    | Runtime.NextState new_state -> y new_state
    | other -> other
  in

  let rec state_loop state : (unit, Error.connection_error) result =
    let close_faraday () = Faraday.close state.State.writer.faraday in

    match (Fiber.any ~combine (operations state)) state with
    | ConnectionError err ->
        close_faraday ();
        Error err
    | End ->
        close_faraday ();
        Ok ()
    | NextState new_state -> (
        match Writer.write state.State.writer socket with
        | Ok () ->
            if new_state.shutdown && Streams.all_closed new_state.streams then (
              Faraday.close (State.do_flush new_state).writer.faraday;
              Ok ())
            else (state_loop [@tailcall]) (State.do_flush new_state)
        | Error err ->
            Runtime.handle_connection_error ~state err;
            (* error_handler err; *)
            close_faraday ();
            Error err)
  in

  match initial_state_result with
  | Error err ->
      Runtime.handle_connection_error err;
      (* error_handler err *)
      Error err
  | Ok (initial_state, rest_to_parse) ->
      if Cstruct.length rest_to_parse > 0 then
        match
          Runtime.read_io ~debug ~frame_handler initial_state rest_to_parse
        with
        | consumed, NextState next_state ->
            state_loop
              {
                next_state with
                read_off = rest_to_parse.Cstruct.len - consumed;
              }
        | _, End -> Ok ()
        | _, ConnectionError err -> Error err
      else state_loop initial_state
