open Cohttp_eio
open Eio

let () =
  Eio_main.run @@ fun env ->
  (* let cases = H2inspect.run_server_tests ~sw env#clock env#net in *)
  let body_writer : _ Haha.Body.writer = fun _ -> Fiber.await_cancel () in

  let make_request = function
    | H2inspect.Case.GET path ->
        Haha.Request.create
          ~error_handler:(fun c _ -> c)
          ~response_handler:(fun () _ -> (Some Haha.Body.ignore_reader, ()))
          ~context:() GET path
    | POST path ->
        Haha.Request.create_with_streaming
          ~error_handler:(fun c _ -> c)
          ~response_handler:(fun () _ -> (Some Haha.Body.ignore_reader, ()))
          ~context:() ~body_writer POST path
  in

  let connect { H2inspect.Case.port; scenerio = actions } =
    Net.with_tcp_connect ~host:"127.0.0.1" ~service:(string_of_int port) env#net
    @@ fun socket ->
    let initial_iter = Haha.Client.connect socket in

    let req_stream = Stream.create max_int in

    List.iter
      (fun action -> Stream.add req_stream (make_request action))
      actions;

    let rec aux : Haha.Client.iteration -> unit =
     fun { state; _ } ->
      match state with
      | InProgress next ->
          let next_iter =
            Fiber.first
              (fun () -> next [ Request (Stream.take req_stream) ])
              (fun () -> next [])
          in
          aux next_iter
      | End | Error _ -> ()
    in

    aux initial_iter
  in

  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  let client = Client.make ~https:None env#net in
  let _resp, body =
    Client.get ~sw client (Uri.of_string "http://127.0.0.1:3000")
  in
  let cases_json =
    Buf_read.(parse_exn take_all) body ~max_size:max_int
    |> Yojson.Safe.from_string
  in

  let cases =
    let open Yojson.Safe.Util in
    match cases_json with
    | `List l ->
        List.map
          (fun json ->
            let port =
              match member "port" json with
              | `Int d -> d
              | _ -> failwith "Couldn't find \"port\" key in json"
            in
            let scenerio =
              match member "scenerio" json with
              | `List l ->
                  List.map
                    (function
                      | `String s -> (
                          match String.split_on_char ' ' s with
                          | [ "POST"; path ] -> H2inspect.Case.POST path
                          | [ "GET"; path ] -> GET path
                          | _ -> failwith "Wrong format of the scenerio action")
                      | _ -> failwith "Wrong format of the scenerio action")
                    l
              | _ -> failwith "Couldn't find \"scenerio\" key in json"
            in
            { H2inspect.Case.port; scenerio })
          l
    | _ -> assert false
  in

  List.iter connect cases
