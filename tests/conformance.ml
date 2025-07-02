open Eio

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  H2inspect.run_server_tests ~sw env#clock env#net;

  let request =
    Haha.Request.create
      ~error_handler:(fun c _ -> c)
      ~response_handler:(fun () _ -> (Some Haha.Body.ignore_reader, ()))
      ~context:() GET "/"
  in

  let rec connect i port =
    try
      Net.with_tcp_connect ~host:"127.0.0.1" ~service:(string_of_int port)
        env#net (fun socket ->
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
                (* aux (next []) *)
            | End | Error _ -> ()
          in

          aux initial_iter);
      if i > 1 then connect (i - 1) port
    with Exn.Io (Net.E _, _) ->
      Printf.printf "End of tests, exn\n%!";
      ()
  in

  connect 3 8000;
  Time.sleep env#clock 0.01;
  connect 1 8001;
  Time.sleep env#clock 0.01;
  connect 16 8002;
  Time.sleep env#clock 0.01;
  connect 8 8003
