open Haha

type context = int * bool;;

Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let socket =
  Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8080))
in

let payload = Cstruct.create 16 in

let body_writer : context Body.writer =
 fun ((count, received_back) as context) ->
  match received_back with
  | true when count < 10 ->
      let now = Eio.Time.now env#clock |> Int64.bits_of_float in
      Cstruct.BE.set_uint64 payload 0 now;

      {
        payload = `Data [ payload ];
        on_flush = ignore;
        context = (count + 1, false);
      }
  | true -> { payload = `End (None, Headers.empty); on_flush = ignore; context }
  | false -> Eio.Fiber.await_cancel ()
in

let body_reader : context Body.reader =
 fun (count, _) -> function
   | `Data _ ->
       Printf.printf "received data back, count %i\n%!" count;
       (count, true)
   | `End _ ->
       Printf.printf "end of data\n%!";
       (count, true)
in

let error_handler : context -> Error.t -> context =
 fun c -> function
   | StreamError (_, code) ->
       Printf.printf "stream error of code %s\n%!" (Error_code.to_string code);
       c
   | _ -> c
in

let response_handler : context Response.handler =
 fun c response ->
  Format.printf "status %a@." Status.pp_hum (Response.status response);
  (Some body_reader, c)
in

let on_close =
 fun (count, _) -> Printf.printf "stream closed, final count: %i\n%!" count
in

let inputs =
  [
    Client.Request
      (Request.create_with_streaming ~body_writer ~context:(0, true) ~on_close
         ~error_handler ~response_handler POST "/stream");
    Request
      (Request.create_with_streaming ~body_writer ~context:(0, true) ~on_close
         ~error_handler ~response_handler POST "/stream");
    Shutdown;
  ]
in

let initial_iteration = Client.connect socket in

let rec iterate : Client.iter_input list -> Client.iteration -> unit =
 fun inputs -> function
   | { state = End; _ } -> print_endline "end of connection"
   | { state = Error (Exn exn); _ } ->
       Printf.printf "connection error, exn: %s\n%!" (Printexc.to_string exn)
   | { state = Error (PeerError (code, msg)); _ } ->
       Printf.printf "connection error, peer error of code %s: %s\n%!"
         (Error_code.to_string code)
         msg
   | { state = Error (ProtocolViolation (code, msg)); _ } ->
       Printf.printf "connection error, protocol violation of code %s: %s\n%!"
         (Error_code.to_string code)
         msg
   | { state = InProgress next; _ } -> iterate [] (next inputs)
in

iterate inputs initial_iteration
