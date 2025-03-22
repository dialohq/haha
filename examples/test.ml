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
    let headers = Request.headers request in
    print_endline "Headers:";
    List.iter
      (fun (header : Headers.t) ->
        Printf.printf "%s: %s\n%!" header.name header.value)
      headers;
    print_endline "Pseudo-headers:";
    Printf.printf ":method: %s\n%!" @@ Method.to_string meth;
    Printf.printf ":path: %s\n%!" @@ path;
    Printf.printf ":scheme: %s\n%!" @@ Request.scheme request;
    Printf.printf ":authority: %s\n%!"
    @@ Option.value ~default:"None" (Request.authority request);
    match (meth, path) with
    | POST, "/" | GET, "/" | POST, "/stream" ->
        let cs = Cstruct.create 16 in
        let interim_responses =
          Dynarray.make 2 (Response.create_interim `Continue [])
        in
        let data_p, data_r = Eio.Promise.create () in
        let body_writer ~(window_size : int32) =
          Printf.printf "body_writer called\n%!";
          let _ = window_size in
          if not (Eio.Promise.is_resolved data_p) then (
            let recv_data = Eio.Promise.await data_p in
            Cstruct.blit recv_data 0 cs 0 16;
            Cstruct.LE.set_uint64 recv_data 8
              (Eio.Time.now env#clock |> Int64.bits_of_float);
            `Data recv_data)
          else (
            Printf.printf "Writin `End None in API\n%!";
            `End (None, []))
        in

        Request.handle
          ~response_writer:(fun () ->
            Printf.printf "response_writer called\n%!";
            match Dynarray.pop_last_opt interim_responses with
            | Some response -> `Interim response
            | None ->
                let response =
                  Response.create_with_streaming ~body_writer `OK []
                in
                `Final response)
          ~on_data:(fun data ->
            print_bs_hex data;
            Eio.Promise.try_resolve data_r data |> ignore)
    | _ ->
        Request.handle
          ~response_writer:(fun () -> `Final (Response.create `Not_found []))
          ~on_data:ignore
  in
  let connection_handler =
    Server.connection_handler ~error_handler Settings.default request_handler
  in

  Eio.Net.run_server
    ~on_error:(fun exn ->
      Printf.printf "Connection exn: %s\n%!" @@ Printexc.to_string exn)
    server_socket connection_handler
