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
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
  let server_socket =
    Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
  in
  let goaway_condition = Eio.Condition.create () in

  let error_handler (_error : Error.t) =
    Printf.printf "Got error in the erro handler\n%!";
    ()
  in

  let _goaway_writer () = Eio.Condition.await_no_mutex goaway_condition in

  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Time.sleep env#clock 5.;
      Eio.Condition.broadcast goaway_condition;
      `Stop_daemon);

  let request_handler request =
    let path, meth = (Request.path request, Request.meth request) in
    match (meth, path) with
    | POST, "/" | GET, "/" | POST, "/stream" ->
        (* let mailbox = Eio.Stream.create 0 in *)
        let responded = ref false in
        let data_writter = ref false in
        let data = Cstruct.of_string "d" in

        let body_writer (window_size : int32) () =
          let window_size = Int32.to_int window_size in
          if !data_writter then `EOF
          else if Cstruct.length data > window_size then `Yield
          else (
            data_writter := true;
            `Data data)
          (* let recvd = Eio.Stream.take mailbox in *)
          (* Cstruct.LE.set_uint64 recvd 8 *)
          (*   (Eio.Time.now env#clock |> Int64.bits_of_float); *)
        in

        let response =
          Response.create_final_with_streaming ~body_writer `OK []
        in

        Request.handle
          ~response_writer:(fun () ->
            if !responded then Eio.Fiber.await_cancel ();
            responded := true;
            response)
          ~on_data:(fun data ->
            print_bs_hex data;
            () (* Eio.Stream.add mailbox data *))
    | _ -> failwith "not implemented endpoint"
  in
  let connection_handler =
    Server.connection_handler ~error_handler Settings.default request_handler
  in

  Eio.Net.run_server
    ~on_error:(fun _ -> Printexc.print_backtrace stdout)
    server_socket connection_handler
