open Haha

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let print_bs_hex bs =
    String.iter
      (fun c -> Printf.printf "%02X " (Char.code c))
      (Bigstringaf.to_string bs);
    print_newline ()
  in
  let _ = print_bs_hex in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
  let server_socket =
    Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
  in

  Server.listen server_socket env
