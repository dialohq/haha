open Haha

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
  let server_socket =
    Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
  in

  let connection_handler socket addr =
    (match addr with
    | `Unix s -> Printf.printf "Starting connection for %s\n%!" s
    | `Tcp (ip, port) ->
        Format.printf "Starting connection for %a:%i@." Eio.Net.Ipaddr.pp ip
          port);

    let goaway_promise, goaway_resolver = Eio.Promise.create () in

    let error_handler (_error : Error.connection_error) =
      Printf.printf "Got error in the erro handler\n%!"
    in

    let goaway_writer () = Eio.Promise.await goaway_promise in

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
      | GET, "/" | POST, "/stream" ->
          let cs = Cstruct.create 16 in
          let interim_responses =
            Dynarray.make 2 (Response.create_interim `Continue [])
          in
          let data_stream = Eio.Stream.create Int.max_int in
          let iterations = ref 0 in
          let max = 5 in
          let take_data () =
            if !iterations < max then
              let data = Eio.Stream.take data_stream in
              Some data
            else (
              Eio.Promise.resolve goaway_resolver ();
              None)
          in

          let put_data data =
            if !iterations < max then (
              Eio.Stream.add data_stream data;
              incr iterations)
          in

          let body_writer ~window_size:_ =
            match take_data () with
            | None -> (`End (None, []), ignore)
            | Some data ->
                Cstruct.LE.set_uint64 cs 8
                  (Eio.Time.now env#clock |> Int64.bits_of_float);
                Cstruct.blit data 0 cs 0 8;
                (`Data [ cs ], ignore)
          in

          Request.handle ~error_handler:ignore
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
              match data with
              | `Data cs ->
                  Printf.printf "Received %i bytes\n%!" cs.Cstruct.len;
                  put_data cs
              | `End (Some cs, _) ->
                  Cstruct.hexdump cs;
                  put_data cs;
                  Printf.printf "Peer EOF\n%!"
              | `End _ -> Printf.printf "Peer EOF\n%!")
      | POST, "/" ->
          let body_writer ~window_size:_ = (`End (None, []), ignore) in
          Request.handle ~error_handler:ignore
            ~response_writer:(fun () ->
              `Final (Response.create_with_streaming ~body_writer `OK []))
            ~on_data:ignore
      | _ ->
          Request.handle ~error_handler:ignore
            ~response_writer:(fun () -> `Final (Response.create `Not_found []))
            ~on_data:ignore
    in

    Server.connection_handler ~goaway_writer ~error_handler
      ~config:Settings.default request_handler socket addr;
    Printf.printf "End of TCP connection\n%!"
  in

  Eio.Net.accept_fork ~sw
    ~on_error:(fun exn ->
      Printf.printf "Connection exn: %s\n%!" @@ Printexc.to_string exn)
    server_socket connection_handler
