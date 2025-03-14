open Haha

let () =
  let print_bs_hex bs =
    String.iter
      (fun c -> Printf.printf "%02X " (Char.code c))
      (Cstruct.to_string bs);
    print_newline ()
  in
  let _ = print_bs_hex in

  (* let faraday = Faraday.create 1000 in *)
  (* let hpack_encoder = Hpack.Encoder.create 1000 in *)
  (* let headers : Hpack.header list = *)
  (*   [ *)
  (*     { Hpack.name = ":authority"; value = "localhost:8080"; sensitive = false }; *)
  (*     { name = ":method"; value = "POST"; sensitive = false }; *)
  (*     { name = ":path"; value = "/stream"; sensitive = false }; *)
  (*     { name = ":scheme"; value = "http"; sensitive = false }; *)
  (*     { *)
  (*       name = "content-type"; *)
  (*       value = "application/octet-stream"; *)
  (*       sensitive = false; *)
  (*     }; *)
  (*     { name = "accept-encoding"; value = "gzip"; sensitive = false }; *)
  (*     { name = "user-agent"; value = "Go-http-client/2.0"; sensitive = false }; *)
  (*   ] *)
  (* in *)
  (* let length = *)
  (*   List.fold_left *)
  (*     (fun acc header -> *)
  (*       acc + Hpack.Encoder.calculate_length hpack_encoder header) *)
  (*     0 headers *)
  (* in *)
  (* List.iter *)
  (*   (fun header -> Hpack.Encoder.encode_header hpack_encoder faraday header) *)
  (*   headers; *)
  (* let encoded = Faraday.serialize_to_bigstring faraday in *)
  (* print_bs_hex encoded; *)
  (* Printf.printf "length: %i | by len_ref: %i\n%!" *)
  (*   (Bigstringaf.length encoded) *)
  (*   length; *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
  let server_socket =
    Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
  in

  let request_handler request =
    let path, meth = (Request.path request, Request.meth request) in
    match (meth, path) with
    | POST, "/stream" ->
        let mailbox = Eio.Stream.create 0 in
        let responded = ref false in

        let body_writer () =
          let recvd = Eio.Stream.take mailbox in

          Cstruct.LE.set_uint64 recvd 8
            (Eio.Time.now env#clock |> Int64.bits_of_float);
          `Data recvd
        in

        let response =
          Response.create_final_with_streaming ~body_writer `OK []
        in

        Request.handle
          ~response_writer:(fun () ->
            if !responded then Eio.Fiber.await_cancel ();
            responded := true;
            response)
          ~on_data:(fun data -> Eio.Stream.add mailbox data)
    | _ -> failwith "chuj"
  in
  let connection_handler = Server.connection_handler request_handler in

  Eio.Net.run_server ~on_error:ignore server_socket connection_handler
