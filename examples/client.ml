open Haha

let body_writer : unit -> Body.writer =
 fun () ->
  let c = ref false in
  fun () ->
    let res =
      if !c then `End (None, Headers.empty)
      else `Data [ Cstruct.of_string "dupa" ]
    in
    c := true;
    res

let body_reader : Body.reader = fun _data -> ()
let response_handler : Respd.handler = fun _respd -> Some body_reader

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

  let request () =
    Request.create_with_streaming ~body_writer:(body_writer ())
      ~response_handler
      ~error_handler:(fun _ -> print_endline "stream erra")
      POST "/"
  in

  iterate [ request (); request () ] (Client.connect socket)
