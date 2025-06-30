open Eio

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  H2inspect.run_server_tests ~sw env#net;

  let request =
    Haha.Request.create
      ~error_handler:(fun c _ -> c)
      ~response_handler:(fun () _ -> (Some Haha.Body.ignore_reader, ()))
      ~context:() GET "/"
  in

  let rec connect () =
    try
      Net.with_tcp_connect ~host:"127.0.0.1" ~service:"8000" env#net
        (fun socket ->
          let initial_iter = Haha.Client.connect socket in

          let send_request = Condition.create () in

          Fiber.fork ~sw (fun () ->
              Time.sleep env#clock 0.1;
              Condition.broadcast send_request);

          let rec aux : Haha.Client.iteration -> unit =
           fun { state; _ } ->
            match state with
            | InProgress next ->
                let next_iter =
                  Fiber.first
                    (fun () ->
                      Condition.await_no_mutex send_request;
                      next [ Request request ])
                    (fun () -> next [])
                in
                aux next_iter
            | End | Error _ -> ()
          in

          aux initial_iter);
      connect ()
    with Exn.Io (Net.E _, _) ->
      Printf.printf "End of tests\n%!";
      ()
  in

  connect ()
