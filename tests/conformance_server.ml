let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let response_writer : unit Haha.Response.response_writer =
   fun () -> `Final (Haha.Response.create `OK)
  in
  let handler : Haha.Reqd.handler =
   fun _ ->
    Haha.Reqd.handle ~context:() ~response_writer
      ~body_reader:Haha.Body.ignore_reader
      ~error_handler:(fun c _ -> c)
      ()
  in

  let connection_handler =
    Haha.Server.connection_handler ~error_handler:ignore handler
  in
  let socket =
    Eio.Net.listen ~backlog:10 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.any, 8080))
  in

  Eio.Net.run_server ~on_error:ignore socket connection_handler
