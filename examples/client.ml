open Haha

let () =
  let print_bs_hex bs =
    String.iter
      (fun c -> Printf.printf "%02X " (Char.code c))
      (Cstruct.to_string bs);
    print_newline ()
  in
  let _ = print_bs_hex in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8080))
  in

  let body_writer ~window_size:_ = `End (Some (Cstruct.of_string "dupa"), []) in

  let response_handler (response : Response.t) =
    let status = Response.status response in
    Printf.printf "Got response of status %s\n%!" @@ Status.to_string status;

    Response.handle ~on_data:(fun cs -> print_bs_hex cs)
  in

  let sample_request =
    Request.create_with_streaming ~body_writer ~response_handler ~headers:[]
      POST "/"
  in
  let requests = Dynarray.of_list [ sample_request ] in

  let written = ref false in

  let request_writer () =
    Printf.printf "Request writer called\n%!";
    if !written then Eio.Fiber.await_cancel () else written := true;
    Dynarray.pop_last requests
  in

  Client.run ~error_handler:ignore ~request_writer Settings.default socket
