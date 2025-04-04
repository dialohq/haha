open Haha

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8080))
  in

  let max = 10 in
  let data_stream = Eio.Stream.create 0 in

  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop sent : unit =
        if sent < max then (
          Eio.Time.sleep env#clock 1.;
          let cs = Cstruct.create 16 in
          Cstruct.LE.set_uint64 cs 0
            (Eio.Time.now env#clock |> Int64.bits_of_float);
          Eio.Stream.add data_stream (`Data [ cs ]);
          loop (sent + 1))
        else Eio.Stream.add data_stream (`End (None, []))
      in
      loop 0;

      `Stop_daemon);

  let body_writer ~window_size:_ = (Eio.Stream.take data_stream, ignore) in

  let response_handler (response : Response.t) =
    let status = Response.status response in
    Printf.printf "Got response of status %s\n%!" @@ Status.to_string status;

    Response.handle ~on_data:(fun cs ->
        match cs with
        | `Data cs -> Cstruct.hexdump cs
        | `End (Some cs, _) ->
            Cstruct.hexdump cs;
            Printf.printf "Peer EOF\n%!"
        | `End _ -> Printf.printf "Peer EOF\n%!")
  in

  let sample_request =
    Request.create_with_streaming ~body_writer ~response_handler ~headers:[]
      POST "/stream"
  in
  let requests = Dynarray.of_list [ sample_request ] in

  let written = ref false in

  let request_writer () =
    Printf.printf "Request writer called\n%!";
    if !written then Eio.Fiber.await_cancel () else written := true;
    Dynarray.pop_last requests
  in

  Client.run ~error_handler:ignore ~request_writer Settings.default socket
