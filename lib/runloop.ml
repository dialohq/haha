open Eio

let start :
    'a 'b.
    ?request_writer_handler:(('a, 'b) State.t -> ('a, 'b) State.t) ->
    ?await_user_goaway:(unit -> unit) ->
    ?get_response_writers:(('a, 'b) State.t -> (unit -> ('a, 'b) State.t) list) ->
    ?combine_states:(('a, 'b) State.t -> ('a, 'b) State.t -> ('a, 'b) State.t) ->
    get_body_writers:(('a, 'b) State.t -> (Types.body_writer * int32) list) ->
    initial_state_result:
      (('a, 'b) State.t * Cstruct.t, Error.connection_error) result ->
    frame_handler:(Frame.t -> ('a, 'b) State.t -> ('a, 'b) State.t option) ->
    receive_buffer:Cstruct.t ->
    _ ->
    _ =
 fun ?request_writer_handler ?await_user_goaway ?get_response_writers
     ?combine_states ~get_body_writers ~initial_state_result ~frame_handler
     ~receive_buffer socket ->
  let read_loop state off =
    let read_bytes =
      Flow.single_read socket
        (Cstruct.sub receive_buffer off (Cstruct.length receive_buffer - off))
    in
    let consumed, next_state =
      Runtime.read_io ~frame_handler state
        (Cstruct.sub receive_buffer 0 (read_bytes + off))
    in
    let unconsumed = read_bytes + off - consumed in
    Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
    match next_state with
    | None ->
        Printf.printf "Closing TCP connection\n%!";
        `End
    | Some next_state -> `Read (unconsumed, next_state)
  in

  let rec state_loop read_off state =
    let operations =
      let read_op = fun () -> read_loop state read_off in
      let add_request_writer_handler ops =
        match request_writer_handler with
        | None -> ops
        | Some request_writer_handler ->
            (fun () -> `NextState (request_writer_handler state)) :: ops
      in

      let add_response_writer_handlers ops =
        match get_response_writers with
        | None -> ops
        | Some get_response_writers ->
            let response_ops =
              get_response_writers state
              |> List.map (fun writer () -> `NextState (writer ()))
            in
            List.concat [ ops; response_ops ]
      in

      let add_body_writer_ops ops =
        let body_ops =
          get_body_writers state
          |> List.map (fun (f, id) () ->
                 `NextState
                   (Runtime.body_writer_handler
                      ~write:(fun () -> Writer.write state.writer socket)
                      state f id))
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
              `NoChange)
            :: ops
      in

      [ read_op ] |> add_request_writer_handler |> add_response_writer_handlers
      |> add_goaway_handler |> add_body_writer_ops
    in

    (* race condition of responding immediately to multiple requests *)
    let combine =
     fun x y ->
      match ((x, y), combine_states) with
      | (`NextState state1, `NextState state2), Some combine ->
          `NextState (combine state1 state2)
      | _ -> x
    in

    let new_state = Fiber.any ~combine operations in

    Writer.write state.writer socket;

    match new_state with
    | `End -> Faraday.close state.writer.faraday
    | `Read (unconsumed, next_state) -> state_loop unconsumed next_state
    | `NoChange -> state_loop read_off state
    | `NextState next_state -> state_loop read_off next_state
  in

  match initial_state_result with
  | Error err ->
      Runtime.handle_connection_error err;
      Printf.printf "Closing TCP connection\n%!"
  | Ok (state, rest_to_parse) -> (
      match Runtime.read_io ~frame_handler state rest_to_parse with
      | consumed, Some next_state ->
          state_loop (rest_to_parse.Cstruct.len - consumed) next_state
      | _, None -> Printf.printf "Closing TCP connection\n%!")
