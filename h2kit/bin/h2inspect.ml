open Eio
open H2kit

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
    let open Serializers in
    Printf.printf "Starting the client\n%!";
    Net.with_tcp_connect ~host:"127.0.0.1" ~service:"8000" env#net (fun flow ->
        let faraday = Faraday.create 10_000 in
        write_connection_preface faraday;
        write_ping_frame faraday
          (Cstruct.of_string "12345678")
          (create_frame_info 0l);

        Faraday.write_uint8 faraday 0;
        Faraday.write_uint8 faraday 0;
        let ba = Faraday.serialize_to_bigstring faraday in

        Flow.write flow [ Cstruct.of_bigarray ba ];

        Fiber.await_cancel ())
  in

  Fiber.both run_server run_client
