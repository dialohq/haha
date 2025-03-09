open Eio

let start ~max_frame_size ~(initial_state : 'a)
    ~(read_io : 'a -> Cstruct.t -> int * 'a option)
    ~(write_io : unit -> Cstruct.t) socket =
  let receive_buffer = Cstruct.create max_frame_size in
  let rec read_loop off state : unit =
    let read_bytes =
      Flow.single_read socket
        (Cstruct.sub receive_buffer off (Cstruct.length receive_buffer - off))
    in
    let consumed, next_state =
      read_io state (Cstruct.sub receive_buffer off read_bytes)
    in
    match next_state with
    | None -> ()
    | Some next_state -> read_loop (read_bytes - consumed) next_state
  in

  let rec write_loop () : unit =
    Flow.write socket [ write_io () ];

    write_loop ()
  in

  Fiber.first (fun () -> read_loop 0 initial_state) write_loop
