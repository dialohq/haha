open Eio

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  let cases = H2inspect.run_server_tests ~sw env#clock env#net in
  let body_writer : Cstruct.t option Haha.Body.writer = function
    | Some cs -> { payload = `Data [ cs ]; on_flush = ignore; context = None }
    | None -> Fiber.await_cancel ()
  in

  let make_stream = function
    | H2inspect.Case.GET path ->
        Haha.Request.create
          ~error_handler:(fun c _ -> c)
          ~response_handler:(fun c _ -> (Some Haha.Body.ignore_reader, c))
          ~context:None GET path
    | POST (path, 0) ->
        Haha.Request.create_with_streaming
          ~error_handler:(fun c _ -> c)
          ~response_handler:(fun c _ -> (Some Haha.Body.ignore_reader, c))
          ~context:None ~body_writer POST path
    | POST (path, n) ->
        let context =
          let cs = Cstruct.create n in
          Cstruct.memset cs 0;
          Some cs
        in
        Haha.Request.create_with_streaming
          ~error_handler:(fun c _ -> c)
          ~response_handler:(fun c _ -> (Some Haha.Body.ignore_reader, c))
          ~context ~body_writer POST path
  in

  let connect { H2inspect.Case.port; streams; settings } =
    (* Fiber.fork ~sw @@ fun () -> *)
    Net.with_tcp_connect ~host:"127.0.0.1" ~service:(string_of_int port) env#net
    @@ fun socket ->
    let config = H2kit.Settings.(update_with_list default settings) in
    let initial_iter = Haha.Client.connect ~config socket in

    let inputs =
      streams
      |> List.map @@ fun stream -> Haha.Client.Request (make_stream stream)
    in

    let rec aux : Haha.Client.iteration -> Haha.Client.iter_input list -> unit =
     fun { state; _ } ins ->
      match state with
      | InProgress next ->
          let next_iter = next ins in
          aux next_iter []
      | End | Error _ -> ()
    in

    aux initial_iter inputs
  in

  List.iter connect cases
