open Eio

type action = GET of string | POST of string
type script_group = { port : int; count : int; scenerio : action list }

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  H2inspect.run_server_tests ~sw env#clock env#net;

  let body_writer : _ Haha.Body.writer = fun _ -> Fiber.await_cancel () in

  let make_request = function
    | GET path ->
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

  let rec connect i port actions =
    try
      Net.with_tcp_connect ~host:"127.0.0.1" ~service:(string_of_int port)
        env#net (fun socket ->
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

          aux initial_iter);
      if i > 1 then connect (i - 1) port actions
    with Exn.Io (Net.E _, _) ->
      Printf.printf "End of tests, exn\n%!";
      ()
  in

  let script : Yojson.Safe.t =
    In_channel.with_open_text "scenerio.json" @@ fun chan ->
    Yojson.Safe.from_channel chan
  in

  let script =
    let open Yojson.Safe.Util in
    match script with
    | `Assoc l ->
        List.map
          (fun (port, json) ->
            let port = int_of_string port in
            let count =
              match member "count" json with
              | `Int d -> d
              | _ -> failwith "Couldn't find \"count\" key in json"
            in
            let scenerio =
              match member "scenerio" json with
              | `List l ->
                  List.map
                    (function
                      | `String s -> (
                          match String.split_on_char ' ' s with
                          | [ "POST"; path ] -> POST path
                          | [ "GET"; path ] -> GET path
                          | _ -> failwith "Wrong format of the scenerio action")
                      | _ -> failwith "Wrong format of the scenerio action")
                    l
              | _ -> failwith "Couldn't find \"scenerio\" key in json"
            in
            { port; count; scenerio })
          l
    | _ -> assert false
  in

  List.iter
    (fun { port; count; scenerio } -> connect count port scenerio)
    script

(* connect 3 8000; *)
(* Time.sleep env#clock 0.01; *)
(* connect 1 8001; *)
(* Time.sleep env#clock 0.01; *)
(* connect 16 8002; *)
(* Time.sleep env#clock 0.01; *)
(* connect 9 8003; *)
(* Time.sleep env#clock 0.01; *)
(* connect 1 8004; *)
(* Time.sleep env#clock 0.01; *)

(* connect 4 8005; *)
(* Time.sleep env#clock 0.01; *)
(* connect 4 8006; *)
(* Time.sleep env#clock 0.01; *)
(* connect 5 8007; *)
(* Time.sleep env#clock 0.01; *)
(* connect 5 8008 *)
