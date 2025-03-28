open Eio

let start :
    'a 'b.
    ?request_writer_handler:
      (('a, 'b) State.t -> ('a, 'b) State.frames_state -> ('a, 'b) State.t) ->
    ?await_user_goaway:(unit -> unit) ->
    ?get_response_writers:
      (('a, 'b) State.t ->
      ('a, 'b) State.frames_state ->
      (unit -> ('a, 'b) State.t) list) ->
    ?combine_states:
      (('a, 'b) State.frames_state ->
      ('a, 'b) State.frames_state ->
      ('a, 'b) State.frames_state) ->
    max_frame_size:int ->
    get_body_writers:
      (('a, 'b) State.frames_state -> (Types.body_writer * int32) list) ->
    initial_state:('a, 'b) State.t ->
    token_handler:(Types.token -> ('a, 'b) State.t -> ('a, 'b) State.t option) ->
    _ ->
    _ ->
    _ =
 fun ?request_writer_handler ?await_user_goaway ?get_response_writers
     ?combine_states ~max_frame_size ~get_body_writers ~initial_state
     ~token_handler _port socket ->
  let receive_buffer = Cstruct.create (max_frame_size + 9) in

  let read_loop state off =
    let read_bytes =
      Flow.single_read socket
        (Cstruct.sub receive_buffer off (Cstruct.length receive_buffer - off))
    in
    let consumed, next_state =
      Runtime.read_io ~token_handler state
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

  let write faraday =
    match Faraday.operation faraday with
    | `Close ->
        (* TODO: report internal error *)
        ()
    | `Yield -> ()
    | `Writev bs_list ->
        let written, cs_list =
          List.fold_left_map
            (fun acc { Faraday.buffer; off; len } ->
              (acc + len, Cstruct.of_bigarray buffer ~off ~len))
            0 bs_list
        in
        Flow.write socket (List.rev cs_list);
        Faraday.shift faraday written
  in

  let rec state_loop read_off state =
    let operations =
      let read_op = fun () -> read_loop state read_off in
      match state.State.phase with
      | Preface _ -> (
          match await_user_goaway with
          | Some f ->
              (fun () -> Runtime.user_goaway_handler state ~f Int32.zero)
              :: [ read_op ]
          | None -> [ read_op ])
      | Frames frames_state ->
          let add_request_writer_handler ops =
            match request_writer_handler with
            | None -> ops
            | Some request_writer_handler ->
                (fun () ->
                  `NextState (request_writer_handler state frames_state))
                :: ops
          in

          let add_response_writer_handlers ops =
            match get_response_writers with
            | None -> ops
            | Some get_response_writers ->
                let response_ops =
                  get_response_writers state frames_state
                  |> List.map (fun writer () -> `NextState (writer ()))
                in
                List.concat [ ops; response_ops ]
          in

          let add_body_writer_ops ops =
            let body_ops =
              get_body_writers frames_state
              |> List.map (fun (f, id) () ->
                     `NextState
                       (Runtime.body_writer_handler
                          ~write:(fun () -> write state.faraday)
                          state frames_state f id))
            in
            List.concat [ body_ops; ops ]
          in

          let add_goaway_handler ops =
            match await_user_goaway with
            | None -> ops
            | Some f ->
                (fun () ->
                  Runtime.user_goaway_handler state ~f
                    frames_state.streams.last_client_stream)
                :: ops
          in

          [ read_op ] |> add_request_writer_handler
          |> add_response_writer_handlers |> add_goaway_handler
          |> add_body_writer_ops
    in

    (* race condition of responding immediately to multiple requests *)
    let combine =
     fun x y ->
      match ((x, y), combine_states) with
      | ( ( `NextState ({ State.phase = Frames frames_state1; _ } as state),
            `NextState { State.phase = Frames frames_state2; _ } ),
          Some combine ) ->
          `NextState
            { state with phase = Frames (combine frames_state1 frames_state2) }
      | _ -> x
    in

    let new_state = Fiber.any ~combine operations in

    write state.faraday;

    match new_state with
    | `End -> Faraday.close state.faraday
    | `Read (unconsumed, next_state) -> state_loop unconsumed next_state
    | `NoChange -> state_loop read_off state
    | `NextState next_state -> state_loop read_off next_state
  in
  state_loop 0 initial_state
