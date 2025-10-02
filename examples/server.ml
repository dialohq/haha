open Haha

let body_writer : unit Body.writer =
 fun () -> { payload = `End (None, Headers.empty); context = () }

let body_reader : unit Body.reader = fun () _data -> ()

let response_writer : unit Response.response_writer =
 fun () -> `Final (Response.create_with_streaming ~body_writer `OK)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~reuse_port:true ~backlog:10 ~sw env#net
      (`Tcp (Eio.Net.Ipaddr.V4.any, 8080))
  in

  let request_handler : Reqd.handler =
   fun _ ->
    Reqd.handle ~context:() ~response_writer ~body_reader
      ~error_handler:(fun _ _ -> print_endline "stream erra")
      ()
  in

  let connection_handler =
    Server.connection_handler
      ~error_handler:(fun _ -> print_endline "conn erra")
      request_handler
  in

  Eio.Net.run_server ~on_error:raise socket connection_handler
