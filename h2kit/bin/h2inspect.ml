open Eio
open H2kit

module Buf_write = struct
  include Buf_write

  let write_uint8 = uint8
  let write_string = string

  let schedule_bigstring t ?off ?len bs =
    let cs = Cstruct.of_bigarray bs ?off ?len in
    schedule_cstruct t cs

  module BE = struct
    include BE

    let write_uint32 = uint32
    let write_uint16 = uint16
  end
end

let () =
  Eio_main.run @@ fun env ->
  let run_server () =
    Switch.run @@ fun sw ->
    let socket port =
      Net.listen ~sw ~backlog:10 ~reuse_addr:true env#net
        (`Tcp (Net.Ipaddr.V4.any, port))
    in
    Printf.printf "Starting the server\n%!";
    Net.accept_fork ~sw ~on_error:ignore (socket 8000) (fun flow _ ->
        Reader.run ~sw flow;
        Fiber.await_cancel ())
  in

  let run_client () =
    let open Serializers.Make (Buf_write) in
    Printf.printf "Starting the client\n%!";
    Net.with_tcp_connect ~host:"127.0.0.1" ~service:"8000" env#net (fun flow ->
        Buf_write.with_flow flow @@ fun bw ->
        Buf_write.pause bw;
        write_connection_preface bw;
        write_ping_frame bw
          (Cstruct.of_string "12345678")
          (create_frame_info 0l);

        Buf_write.flush bw;

        Fiber.await_cancel ())
  in

  Fiber.both run_server run_client
