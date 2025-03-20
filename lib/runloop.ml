open Eio

let start ~max_frame_size ~(initial_state : State.t) ?await_user_goaway
    ~(read_io : State.t -> Cstruct.t -> int * State.t option) socket =
  let receive_buffer = Cstruct.create max_frame_size in

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
    `Read
      (match next_state with
      | None ->
          Printf.printf "Closing TCP connection\n%!";
          None
      | Some next_state -> Some (unconsumed, next_state))
  in

  let rec state_loop read_off state =
    let user_write_handler f (frames_state : State.frames_state) =
      match f with
      | `ResponseWriter (f, id) -> (
          let user_response = f () in

          Serialize.write_headers_response state.State.faraday
            state.hpack_encoder id ~end_headers:true user_response;
          Serialize.write_window_update state.faraday id
            Flow_control.WindowSize.initial_increment;

          match user_response.response_type with
          | Unary -> `User state
          | Streaming body_writer ->
              let new_frames_state =
                {
                  frames_state with
                  streams =
                    Streams.insert_body_writer frames_state.streams id
                      body_writer;
                }
              in
              `User { state with phase = Frames new_frames_state })
      | `BodyWriter (f, id) -> (
          let stream_flow =
            match Streams.flow_of_id frames_state.streams id with
            | None -> failwith "dupa"
            | Some x -> x
          in

          match f stream_flow.out_flow () with
          | `Data { Cstruct.buffer; off; len } -> (
              match
                Flow_control.incr_sent stream_flow (Int32.of_int len)
                  ~initial_window_size:
                    frames_state.peer_settings.initial_window_size
              with
              | Error _ -> failwith "window overflow, report to user"
              | Ok new_flow ->
                  Serialize.write_data state.faraday buffer ~off ~len id false;
                  let new_frames_state =
                    {
                      frames_state with
                      streams =
                        Streams.update_stream_flow frames_state.streams id
                          new_flow;
                    }
                  in
                  `User { state with phase = Frames new_frames_state })
          | `EOF ->
              Serialize.write_data state.faraday Bigstringaf.empty ~off:0 ~len:0
                id true;
              let new_frames_state =
                match Streams.state_of_id frames_state.streams id with
                | Open (stream_reader, _) ->
                    {
                      frames_state with
                      streams =
                        Streams.stream_transition frames_state.streams id
                          (Half_closed (Local stream_reader));
                    }
                | _ ->
                    {
                      frames_state with
                      streams =
                        Streams.stream_transition frames_state.streams id Closed;
                    }
              in
              `User { state with phase = Frames new_frames_state }
          | `Yield -> Eio.Fiber.await_cancel ())
    in

    let handle_user_goaway ~f last_client_id =
      f ();
      Printf.printf "Starting shutdown\n%!";
      Serialize.write_goaway state.faraday last_client_id Error_code.NoError
        Bigstringaf.empty;
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
                  (fun () -> handle_user_goaway ~f Int32.zero);
                ]
          | None -> read_loop state read_off)
      | Frames frames_state ->
          let user_writes = State.search_for_writes frames_state in

          let user_writes_handlers =
            List.map (fun f () -> user_write_handler f frames_state) user_writes
          in

          let fs =
            match await_user_goaway with
            | Some f ->
                (fun () -> read_loop state read_off)
                :: (fun () ->
                  handle_user_goaway ~f frames_state.streams.last_client_stream)
                :: user_writes_handlers
            | None ->
                (fun () -> read_loop state read_off) :: user_writes_handlers
          in

          Fiber.any
            ~combine:(fun x y ->
              match (x, y) with
              | ( `User ({ State.phase = Frames frames_state1; _ } as state),
                  `User { phase = Frames frames_state2; _ } ) ->
                  let new_frames_state =
                    {
                      frames_state1 with
                      streams =
                        Streams.combine_after_response frames_state1.streams
                          frames_state2.streams;
                    }
                  in

                  `User { state with phase = Frames new_frames_state }
              | _ -> x)
            fs
    in

    (match Faraday.operation state.State.faraday with
    | `Close | `Yield -> ()
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
    | `Read None -> Faraday.close state.faraday
    | `Read (Some (unconsumed, next_state)) -> state_loop unconsumed next_state
    | `NoChange -> state_loop read_off state
    | `User next_state -> state_loop read_off next_state
  in
  state_loop 0 initial_state
