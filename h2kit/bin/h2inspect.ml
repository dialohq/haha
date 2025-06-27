open Eio

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  let server_socket port =
    Net.listen ~sw ~backlog:10 ~reuse_addr:true env#net
      (`Tcp (Net.Ipaddr.V4.any, port))
  in

  Net.accept_fork ~sw ~on_error:ignore (server_socket 8000) (fun flow _ ->
      let _ = flow in
      ())
