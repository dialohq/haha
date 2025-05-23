open Haha

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8080))
  in

  let max = 10 in
  let data_stream = Eio.Stream.create 0 in

  let send_data data =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add data_stream (data, Eio.Promise.resolve r);
    Eio.Promise.await p
  in

  let body_writer ~window_size:_ = Eio.Stream.take data_stream in

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
    Request.create_with_streaming ~error_handler:ignore ~body_writer
      ~response_handler ~headers:[] POST "/stream"
  in
  (* let requests = Dynarray.of_list [ sample_request ] in *)
  let req_stream = Eio.Stream.create 0 in

  let request_writer () = Eio.Stream.take req_stream in

  let write_req () = Eio.Stream.add req_stream (Some sample_request) in
  let _write_end () = Eio.Stream.add req_stream None in

  let error_handler = function
    | Haha.Error.ProtocolError (_, msg) ->
        Printf.printf "Received connection error: %s\n%!" msg
    | Exn exn ->
        Printf.printf "Received connection error exn: %s\n%!"
        @@ Printexc.to_string exn
  in

  Eio.Fiber.fork ~sw (fun () ->
      Client.run ~request_writer ~config:Settings.default socket
      |> Result.iter_error error_handler);

  Printf.printf "Writing request...\n%!";
  write_req ();

  let rec loop sent : unit =
    if sent < max then (
      Eio.Time.sleep env#clock 0.2;
      let cs = Cstruct.create 16 in
      Cstruct.LE.set_uint64 cs 0 (Eio.Time.now env#clock |> Int64.bits_of_float);
      send_data (`Data [ cs ]);
      loop (sent + 1))
    else send_data (`End (None, []))
  in
  loop 0
