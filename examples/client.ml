open Haha

let body_writer : unit Body.writer =
 fun () -> { payload = `End (None, Headers.empty); context = () }

let body_reader : unit Body.reader = fun () _data -> ()

let response_handler : unit Respd.handler =
 fun () _respd -> (Some body_reader, ())

let rec iterate : Request.t list -> Client.iteration -> unit =
 fun reqs -> function
  | `End -> ()
  | `Error _err -> print_endline "conn erra"
  | `InProgress next -> iterate [] (next reqs)
  | `Shutdown next -> iterate [] (next ())

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8080))
  in

  let request =
    Request.create_with_streaming ~context:() ~body_writer ~response_handler
      ~error_handler:(fun _ _ -> print_endline "stream erra")
      POST "/"
  in

  iterate [ request ] (Client.connect socket)
