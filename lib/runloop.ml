open Eio

let start :
    'a 'b.
    ?request_writer_handler:(('a, 'b) State.t -> ('a, 'b) State.t) ->
    ?await_user_goaway:(unit -> unit) ->
    ?get_response_writers:(('a, 'b) State.t -> (unit -> ('a, 'b) State.t) list) ->
    combine_states:(('a, 'b) State.t -> ('a, 'b) State.t -> ('a, 'b) State.t) ->
    get_body_writers:(('a, 'b) State.t -> (Types.body_writer * int32) list) ->
    initial_state_result:
      (('a, 'b) State.t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> ('a, 'b) State.t -> ('a, 'b) State.t option) ->
    receive_buffer:Cstruct.t ->
    pp_hum_state:(Format.formatter -> ('a, 'b) State.t -> unit) ->
    semaphore:Eio.Semaphore.t ->
    debug:bool ->
    _ ->
    _ =
 fun ?request_writer_handler ?await_user_goaway ?get_response_writers
     ~combine_states ~get_body_writers ~initial_state_result ~frame_handler
     ~receive_buffer ~pp_hum_state ~semaphore ~debug socket ->
  let read_count = ref 0 in
  let read_loop state off =
    try
      if debug then Printf.printf "[HAHAPARSE] Reading from socket\n%!";
      let read_bytes =
        Flow.single_read socket
          (Cstruct.sub receive_buffer off (Cstruct.length receive_buffer - off))
      in
      incr read_count;
      let current_value = !read_count in
      if debug then
        Printf.printf
          "[HAHAPARSE] Read from socket, parse_state continue is %b count: %i\n\
           %!"
          (Option.is_some state.State.parse_state)
          current_value;

      let consumed, next_state, frames =
        Runtime.read_io ~debug ~frame_handler state
          (Cstruct.sub receive_buffer 0 (read_bytes + off))
      in
      if debug then
        Printf.printf "[HAHAPARSE] Read %i bytes, consumed %i, count: %i\n%!"
          read_bytes consumed !read_count;
      let unconsumed = read_bytes + off - consumed in
      Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
      match next_state with
      | None ->
          Printf.printf "Closing TCP connection\n%!";
          `End
      | Some next_state -> `WithOffset (unconsumed, next_state, frames)
    with End_of_file ->
      Runtime.handle_connection_error ~state
        (Error_code.InternalError, "End_of_file");
      `End
  in

  let rec state_loop read_off state rest_frames =
    if debug then
      Format.printf "Rest frames: %a@."
        (Format.pp_print_list Frame.pp_hum ~pp_sep:(fun x () ->
             Format.pp_print_string x " | "))
        rest_frames;
    let operations =
      let base_op =
        match rest_frames with
        | [] -> fun () -> read_loop state read_off
        | frame :: rest -> (
            fun () ->
              match frame_handler frame state with
              | None -> `End
              | Some next_state -> `WithOffset (read_off, next_state, rest))
      in
      let add_request_writer_handler ops =
        match request_writer_handler with
        | None -> ops
        | Some request_writer_handler ->
            (fun () -> `Request (request_writer_handler state)) :: ops
      in

      let add_response_writer_handlers ops =
        match get_response_writers with
        | None -> ops
        | Some get_response_writers ->
            let response_ops =
              get_response_writers state
              |> List.map (fun writer () -> `Response (writer ()))
            in
            List.concat [ ops; response_ops ]
      in

      let add_body_writer_ops ops =
        let body_ops =
          get_body_writers state
          |> List.map (fun (f, id) () ->
                 let res =
                   `Body
                     (Runtime.body_writer_handler
                        ~write:(fun () -> Writer.write state.writer socket)
                        state f id)
                 in

                 if debug then
                   Printf.printf "Body writer acquiring semaphore\n%!";
                 Eio.Semaphore.acquire semaphore;
                 if debug then
                   Printf.printf "Body writer releasing semaphore\n%!";
                 Eio.Semaphore.release semaphore;
                 if debug then Printf.printf "Body writer returning\n%!";
                 res)
        in
        List.concat [ body_ops; ops ]
      in

      let add_goaway_handler ops =
        match await_user_goaway with
        | None -> ops
        | Some f ->
            (fun () ->
              Runtime.user_goaway_handler state ~f
                state.streams.last_client_stream;
              `Same)
            :: ops
      in

      [ base_op ] |> add_request_writer_handler |> add_response_writer_handlers
      |> add_goaway_handler |> add_body_writer_ops
    in

    let pp_hum_operation fmt op =
      let open Format in
      match op with
      | `Request state -> fprintf fmt "Request:@.%a" pp_hum_state state
      | `Response state -> fprintf fmt "Response:@.%a" pp_hum_state state
      | `Body (state, _) -> fprintf fmt "Body:@.%a" pp_hum_state state
      | `Same -> fprintf fmt "NoChange"
      | `End -> fprintf fmt "End"
      | `WithOffset (x, state, _) ->
          fprintf fmt "WithOffset <%i>:@.%a" x pp_hum_state state
      | `WithOffsetBody (x, _, state, _) ->
          fprintf fmt "WithOffsetBody <%i>:@.%a" x pp_hum_state state
    in

    let combines_counter = ref 0 in

    let _combine =
     fun x y ->
      if debug then
        Format.printf "@.>>>>>>>>>>>>>>>>>>>>@.COMBINE %i:@.%a@.%a@."
          !combines_counter pp_hum_operation x pp_hum_operation y;
      incr combines_counter;
      match (x, y) with
      | `Body (state1, on_flush1), `Body (state2, on_flush2) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `Body
            ( combined,
              fun () ->
                on_flush1 ();
                on_flush2 () )
      | `Body (state1, on_flush), `Request state2
      | `Request state1, `Body (state2, on_flush) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `Body (combined, on_flush)
      | `Request state1, `Request state2 ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `Request combined
      | `Response state1, `Response state2 ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `Response combined
      | `Body (state1, on_flush), `Response state2
      | `Response state1, `Body (state2, on_flush) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `Body (combined, on_flush)
      | `WithOffset (off, state1, rest_frames), `Response state2
      | `Response state1, `WithOffset (off, state2, rest_frames) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `WithOffset (off, combined, rest_frames)
      | `WithOffset (off, state1, rest_frames), `Body (state2, on_flush)
      | `Body (state1, on_flush), `WithOffset (off, state2, rest_frames) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `WithOffsetBody (off, on_flush, combined, rest_frames)
      | `WithOffset (off, state1, rest_frames), `Request state2
      | `Request state1, `WithOffset (off, state2, rest_frames) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `WithOffset (off, combined, rest_frames)
      | `WithOffsetBody (off, on_flush, state1, rest_frames), `Response state2
      | `Response state1, `WithOffsetBody (off, on_flush, state2, rest_frames)
      | `WithOffsetBody (off, on_flush, state1, rest_frames), `Request state2
      | `Request state1, `WithOffsetBody (off, on_flush, state2, rest_frames) ->
          let combined = combine_states state1 state2 in
          if debug then
            Format.printf "combined state:@.%a@.<<<<<<<<<<<<<<<<<<<<@."
              pp_hum_state combined;
          `WithOffsetBody (off, on_flush, combined, rest_frames)
      | `End, _ | _, `End -> `End
      | `Same, x | x, `Same -> x
      | _ -> failwith "unhandled race condition in HTTP/2"
    in

    let new_state = Fiber.any ~combine operations in

    if debug then
      Format.printf "Returning new state:@.%a@." pp_hum_operation new_state;

    Writer.write state.writer socket;

    match new_state with
    | `End -> Faraday.close state.writer.faraday
    | `WithOffset (unconsumed, next_state, rest_frames) ->
        state_loop unconsumed next_state rest_frames
    | `Same -> state_loop read_off state rest_frames
    | `Response next_state | `Request next_state ->
        state_loop read_off next_state rest_frames
    | `Body (next_state, on_flush) ->
        on_flush ();
        state_loop read_off next_state rest_frames
    | `WithOffsetBody (unconsumed, on_flush, next_state, rest_frames) ->
        on_flush ();
        state_loop unconsumed next_state rest_frames
  in

  match initial_state_result with
  | Error err ->
      Runtime.handle_connection_error err;
      Printf.printf "Closing TCP connection\n%!"
  | Ok (initial_state, rest_to_parse) ->
      if Cstruct.length rest_to_parse > 0 then
        match
          Runtime.read_io ~debug ~frame_handler initial_state rest_to_parse
        with
        | consumed, Some next_state, rest_frames ->
            state_loop
              (rest_to_parse.Cstruct.len - consumed)
              next_state rest_frames
        | _, None, _ -> Printf.printf "Closing TCP connection\n%!"
      else state_loop 0 initial_state []
