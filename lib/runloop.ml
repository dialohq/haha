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
    _ =
 fun ?request_writer_handler ?await_user_goaway ?get_response_writers
     ?combine_states ~max_frame_size ~get_body_writers ~initial_state
     ~token_handler socket ->
  let receive_buffer = Cstruct.create max_frame_size in

  let read_io state cs =
    match Parse.read cs state.State.parse_state with
    | Ok (consumed, frames, new_parse_state) ->
        let state_with_parse = { state with parse_state = new_parse_state } in
        let next_state =
          List.fold_left
            (fun state frame ->
              match state with
              | None -> None
              | Some state -> token_handler frame state)
            (Some state_with_parse) frames
        in
        (consumed, next_state)
    | Error err ->
        let next_state =
          match err with
          | Error.ConnectionError (code, msg) ->
              Runtime.handle_connection_error state code msg
          | StreamError (stream_id, code) ->
              Runtime.handle_stream_error state stream_id code
        in
        (0, next_state)
  in

  let read_loop state off =
    let read_bytes =
      Flow.single_read socket
        (Cstruct.sub receive_buffer off (Cstruct.length receive_buffer - off))
    in
    let consumed, next_state =
      read_io state (Cstruct.sub receive_buffer 0 (read_bytes + off))
    in
    let unconsumed = read_bytes - consumed in
    Cstruct.blit receive_buffer consumed receive_buffer 0 unconsumed;
    match next_state with
    | None ->
        Printf.printf "Closing TCP connection\n%!";
        `End
    | Some next_state -> `Read (unconsumed, next_state)
  in

  let rec state_loop read_off state =
    let user_goaway_handler ~f last_client_id =
      f ();
      Printf.printf "Starting shutdown\n%!";
      Serialize.write_goaway state.State.faraday last_client_id
        Error_code.NoError Bigstringaf.empty;
      `NoChange
    in

    let new_state =
      match state.phase with
      | Preface _ -> (
          match await_user_goaway with
          | Some f ->
              Fiber.any
                [
                  (fun () -> read_loop state read_off);
                  (fun () -> user_goaway_handler ~f Int32.zero);
                ]
          | None -> read_loop state read_off)
      | Frames frames_state ->
          let user_writes_handlers =
            get_body_writers frames_state
            |> List.map (fun (f, id) () ->
                   `NextState
                     (Runtime.body_writer_handler state frames_state f id))
          in

          let user_operations =
            match request_writer_handler with
            | None -> user_writes_handlers
            | Some request_writer_handler ->
                (fun () ->
                  `NextState (request_writer_handler state frames_state))
                :: user_writes_handlers
          in

          let user_operations =
            match await_user_goaway with
            | None -> user_operations
            | Some f ->
                (fun () ->
                  user_goaway_handler ~f frames_state.streams.last_client_stream)
                :: user_operations
          in

          let user_operations =
            match get_response_writers with
            | None -> user_operations
            | Some get_response_writers ->
                let response_writers =
                  get_response_writers state frames_state
                  |> List.map (fun writer () -> `NextState (writer ()))
                in
                List.concat [ user_operations; response_writers ]
          in

          let fs = (fun () -> read_loop state read_off) :: user_operations in

          let combine =
           fun x y ->
            match ((x, y), combine_states) with
            | ( ( `NextState ({ State.phase = Frames frames_state1; _ } as state),
                  `NextState { State.phase = Frames frames_state2; _ } ),
                Some combine ) ->
                `NextState
                  {
                    state with
                    phase = Frames (combine frames_state1 frames_state2);
                  }
            | _ -> x
          in
          Fiber.any ~combine fs
    in

    (match Faraday.operation state.faraday with
    | `Close ->
        (* TODO: report internal error *)
        ()
    | `Yield -> ()
    | `Writev bs_list ->
        let written, cs_list =
          List.fold_left
            (fun ((to_write, cs_list) : int * Cstruct.t list)
                 (bs_iovec : Bigstringaf.t Faraday.iovec) ->
              ( bs_iovec.len + to_write,
                Cstruct.of_bigarray ~off:bs_iovec.off ~len:bs_iovec.len
                  bs_iovec.buffer
                :: cs_list ))
            (0, []) bs_list
        in
        Flow.write socket (List.rev cs_list);
        Faraday.shift state.faraday written);

    match new_state with
    | `End -> Faraday.close state.faraday
    | `Read (unconsumed, next_state) -> state_loop unconsumed next_state
    | `NoChange -> state_loop read_off state
    | `NextState next_state -> state_loop read_off next_state
  in
  state_loop 0 initial_state
