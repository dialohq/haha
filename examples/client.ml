open Haha

type context = bool

let body_writer : context Body.writer = function
  | true -> { payload = `End (None, Headers.empty); context = true }
  | false -> { payload = `Data [ Cstruct.of_string "dupa" ]; context = true }

let body_reader : context Body.reader = fun c _data -> c

let response_handler : context Respd.handler =
 fun c _respd -> (Some body_reader, c)

let rec iterate : Request.t list -> Client.iteration -> unit =
 fun reqs iter ->
  match (iter, reqs) with
  | `End, _ -> ()
  | `Error _err, _ -> print_endline "conn erra"
  | `InProgress next, [] -> iterate [] (next ~shutdown:true [])
  | `InProgress next, reqs -> iterate [] (next reqs)
  | `Shutdown next, _ -> iterate [] (next ())

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8080))
  in

  let request =
    Request.create_with_streaming ~context:false ~body_writer ~response_handler
      ~error_handler:(fun c _ ->
        print_endline "stream erra";
        c)
      POST "/"
  in

  iterate [ request; request ] (Client.connect socket)
