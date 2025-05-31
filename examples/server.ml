open Haha

type context = [ `Data of Cstruct.t | `Wait | `End ];;

Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
let server_socket =
  Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
in

let conn_error_handler : Error.connection_error -> unit = function
  | Exn exn ->
      Printf.printf "connection error, exn: %s\n%!" (Printexc.to_string exn)
  | PeerError (code, msg) ->
      Printf.printf "connection error, peer error of code %s: %s\n%!"
        (Error_code.to_string code)
        msg
  | ProtocolViolation (code, msg) ->
      Printf.printf "connection error, protocol violation of code %s: %s\n%!"
        (Error_code.to_string code)
        msg
in

let body_writer : context Body.writer = function
  | `End -> { payload = `End (None, []); on_flush = ignore; context = `End }
  | `Data cs -> { payload = `Data [ cs ]; on_flush = ignore; context = `Wait }
  | `Wait -> Eio.Fiber.await_cancel ()
in

let body_reader : context Body.reader =
 fun _ -> function `Data cs -> `Data cs | `End _ -> `End
in

let error_handler : context -> Error.t -> context =
 fun c -> function
   | StreamError (_, code) ->
       Printf.printf "stream error of code %s\n%!" (Error_code.to_string code);
       c
   | _ -> c
in

let response_writer : context Response.response_writer =
 fun () -> `Final (Response.create_with_streaming ~body_writer `OK [])
in

let on_close = fun _ -> Printf.printf "stream closed\n%!" in

let request_handler : Reqd.handler =
 fun reqd ->
  Format.printf "%a@." Reqd.pp_hum reqd;

  Reqd.handle ~context:`Wait ~body_reader ~response_writer ~error_handler
    ~on_close ()
in

let connection_handler socket addr =
  (match addr with
  | `Unix s -> Printf.printf "starting connection for %s\n%!" s
  | `Tcp (ip, port) ->
      Format.printf "starting connection for %a:%i@." Eio.Net.Ipaddr.pp ip port);

  Server.connection_handler ~error_handler:conn_error_handler request_handler
    socket addr;

  Printf.printf "end of TCP connection\n%!"
in

Eio.Net.run_server
  ~on_error:(fun exn ->
    Printf.printf "connection exn: %s\n%!" @@ Printexc.to_string exn)
  server_socket connection_handler
