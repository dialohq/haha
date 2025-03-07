let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let print_bs_hex bs =
    String.iter
      (fun c -> Printf.printf "%02X " (Char.code c))
      (Bigstringaf.to_string bs);
    print_newline ()
  in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
  let server_socket =
    Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
  in

  let recv_stream = Eio.Stream.create 0 in

  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () : unit =
        let data = Eio.Stream.take recv_stream in

        Printf.printf "Received data on API:\n%!";

        print_bs_hex data;
        loop ()
      in
      loop ());

  Printf.printf "Listening on port 8080\n%!";
  Haha.Server.listen ~env ~sw recv_stream server_socket
