open Eio

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  H2inspect.run_server_tests ~sw env#net;

  let rec connect () =
    try
      Net.with_tcp_connect ~host:"127.0.0.1" ~service:"8000" env#net
        (fun socket ->
          let initial_iter = Haha.Client.connect socket in

          let rec aux : Haha.Client.iteration -> unit =
           fun { state; _ } ->
            match state with
            | InProgress next -> aux (next [])
            | End | Error _ -> ()
          in

          aux initial_iter);
      connect ()
    with Exn.Io (Net.E _, _) ->
      Printf.printf "End of tests\n%!";
      ()
  in

  connect ()
