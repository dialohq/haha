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

    let error_handler : Error.connection_error -> unit = function
      | Exn exn -> raise exn
      | PeerError (code, msg) ->
          Format.printf "Got conn error %a: %s@." Error_code.pp_hum code msg
      | ProtocolViolation (code, msg) ->
          Format.printf "Error, protocol violated, %a: %s@." Error_code.pp_hum
            code msg
    in

    let goaway_writer () = Eio.Promise.await goaway_promise in

    let request_handler (request : Reqd.t) =
      let path, meth = (Reqd.path request, Reqd.meth request) in
      let headers = Reqd.headers request in
      print_endline "Headers:";
      List.iter
        (fun (header : Header.t) ->
          Printf.printf "%s: %s\n%!" header.name header.value)
        headers;
      print_endline "Pseudo-headers:";
      Printf.printf ":method: %s\n%!" @@ Method.to_string meth;
      Printf.printf ":path: %s\n%!" @@ path;
      Printf.printf ":scheme: %s\n%!" @@ Reqd.scheme request;
      Printf.printf ":authority: %s\n%!"
      @@ Option.value ~default:"None" (Reqd.authority request);
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

          let body_writer _ ~window_size:_ : _ Body.writer_result =
            match take_data () with
            | None ->
                { payload = `End (None, []); on_flush = ignore; context = () }
            | Some data ->
                Cstruct.LE.set_uint64 cs 8
                  (Eio.Time.now env#clock |> Int64.bits_of_float);
                Cstruct.blit data 0 cs 0 8;
                { payload = `Data [ cs ]; on_flush = ignore; context = () }
          in

          {
            Reqd.initial_context = ();
            error_handler =
              (fun c code ->
                Format.printf "Stream error, %a@." Error_code.pp_hum code;
                c);
            response_writer =
              (fun () ->
                Printf.printf "response_writer called\n%!";
                match Dynarray.pop_last_opt interim_responses with
                | Some response -> `Interim response
                | None ->
                    let response =
                      Response.create_with_streaming ~body_writer `OK []
                    in
                    `Final response);
            on_data =
              (fun _ data ->
                match data with
                | `Data cs ->
                    Printf.printf "Received %i bytes\n%!" cs.Cstruct.len;
                    { action = `Continue; context = put_data cs }
                | `End (Some cs, _) ->
                    Cstruct.hexdump cs;
                    Printf.printf "Peer EOF\n%!";
                    { action = `Continue; context = put_data cs }
                | `End _ ->
                    Printf.printf "Peer EOF\n%!";
                    { action = `Continue; context = () });
          }
      | POST, "/" ->
          let body_writer _ ~window_size:_ =
            { Body.payload = `End (None, []); on_flush = ignore; context = () }
          in
          {
            initial_context = ();
            error_handler = (fun c _ -> c);
            response_writer =
              (fun () ->
                `Final (Response.create_with_streaming ~body_writer `OK []));
            on_data = (fun _ _ -> { action = `Continue; context = () });
          }
      | _ ->
          {
            initial_context = ();
            error_handler = (fun c _ -> c);
            response_writer = (fun () -> `Final (Response.create `Not_found []));
            on_data = (fun _ _ -> { action = `Continue; context = () });
          }
    in

    Server.connection_handler ~goaway_writer ~error_handler
      ~config:Settings.default request_handler socket addr;
    Printf.printf "End of TCP connection\n%!"
  in

  Eio.Net.accept_fork ~sw
    ~on_error:(fun exn ->
      Printf.printf "Connection exn: %s\n%!" @@ Printexc.to_string exn)
    server_socket connection_handler
