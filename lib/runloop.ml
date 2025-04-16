open Eio

let start :
    'a 'b.
    initial_state_result:
      (('a, 'b) State.t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> ('a, 'b) State.t -> ('a, 'b) State.t option) ->
    receive_buffer:Cstruct.t ->
    pp_hum_state:(Format.formatter -> ('a, 'b) State.t -> unit) ->
    user_functions_handlers:
      (('a, 'b) State.t -> (unit -> ('a, 'b) State.t -> ('a, 'b) State.t) list) ->
    debug:bool ->
    error_handler:(Error.t -> unit) ->
    _ ->
    _ =
 fun ~initial_state_result ~frame_handler ~receive_buffer ~pp_hum_state:_
     ~user_functions_handlers ~debug ~error_handler socket ->
  let read_loop off =
    let read_bytes =
      try
        Ok
          (Flow.single_read socket
             (Cstruct.sub receive_buffer off
                (Cstruct.length receive_buffer - off)))
      with End_of_file -> Error ()
    in
    fun state ->
      match read_bytes with
      | Error _ ->
          let err = (Error_code.InternalError, "End_of_file") in
          Runtime.handle_connection_error ~state err;
          error_handler (Error.ConnectionError err);
          None
      | Ok read_bytes -> (
          let consumed, next_state =
            Runtime.read_io ~debug ~frame_handler state
              (Cstruct.sub receive_buffer 0 (read_bytes + off))
          in
          let unconsumed = read_bytes + off - consumed in
          Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
          match next_state with
          | None -> None
          | Some next_state -> Some { next_state with read_off = unconsumed })
  in

  let operations state =
    let base_op () = read_loop state.State.read_off in

    let opt_functions =
      user_functions_handlers state
      |> List.map (fun f () ->
             let handler = f () in
             fun state -> Some (handler state))
    in

    base_op :: opt_functions
  in

  let combine x y =
   fun state ->
    match x state with None -> None | Some new_state -> y new_state
  in

  let rec state_loop state =
    match (Fiber.any ~combine (operations state)) state with
    | None -> Faraday.close state.writer.faraday
    | Some new_state -> (
        match Writer.write state.State.writer socket with
        | Ok () ->
            if new_state.shutdown && Streams.all_closed new_state.streams then
              Faraday.close new_state.writer.faraday
            else state_loop (State.do_flush new_state)
        | Error _ -> Faraday.close state.writer.faraday)
  in

  match initial_state_result with
  | Error err -> Runtime.handle_connection_error err
  | Ok (initial_state, rest_to_parse) ->
      if Cstruct.length rest_to_parse > 0 then
        match
          Runtime.read_io ~debug ~frame_handler initial_state rest_to_parse
        with
        | consumed, Some next_state ->
            state_loop
              {
                next_state with
                read_off = rest_to_parse.Cstruct.len - consumed;
              }
        | _, None -> ()
      else state_loop initial_state
