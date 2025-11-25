open Haha

let body_writer : Body.writer = fun () -> `End (None, Headers.empty)

let response_writer : Response.response_writer =
 fun () -> `Final (Response.create ~body_writer `OK)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_reader : Body.reader = function
    | `Data cs ->
        Printf.printf "Received data: %s\n%!" (Cstruct.to_string cs);
        Eio.Time.sleep env#clock 1.
    | `End _ -> ()
  in
  let socket =
    Eio.Net.listen ~reuse_port:true ~backlog:10 ~sw env#net
      (`Tcp (Eio.Net.Ipaddr.V4.any, 8080))
  in

  let request_handler : Reqd.handler =
   fun _ ->
    Reqd.handle ~response_writer ~body_reader
      ~error_handler:(fun _ -> print_endline "stream erra")
      ()
  in

  let connection_handler =
    Server.connection_handler
      ~error_handler:(fun _ -> print_endline "conn erra")
      request_handler
  in

  Eio.Net.run_server ~on_error:raise socket connection_handler
