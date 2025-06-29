module BWrite = Buf_write
open Eio
open H2kit
open Steps

type test = { label : string; steps : step list }
type test_group = { label : string; tests : test list }

let make_socket ~sw ~net port =
  Net.listen ~sw ~backlog:10 ~reuse_addr:true net
    (`Tcp (Net.Ipaddr.V4.any, port))

let test_runner :
    next_element:(unit -> Element.t) ->
    writer:Buf_write.t ->
    int ->
    test ->
    unit =
 fun ~next_element ~writer i { steps; label } ->
  Ocolor_format.printf "  %i. @{<grey>%s@}%!" (i + 1) label;
  let res =
    List.fold_left
      (fun acc a ->
        match (acc, a ()) with
        | (Error _ as err), _ -> err
        | _, Expect f -> f (next_element ())
        | acc, Write f ->
            f writer;
            acc)
      (Ok ()) steps
  in
  match res with
  | Ok () -> Ocolor_format.printf " - @{<green>@{<bold>Pass@}@}@."
  | Error msg ->
      let open Serializers.Make (BWrite) in
      write_goaway_frame ~debug_data:(Cstruct.of_string msg) writer 0l
        InternalError;
      Buf_write.flush writer;
      Ocolor_format.printf " - @{<red>@{<bold>Fail:@} %s@}@." msg

let groups_runner :
    sw:Switch.t -> net:[> _ Net.ty ] Resource.t -> test_group list -> unit =
 fun ~sw ~net ->
  List.iteri @@ fun i { label; tests } ->
  Ocolor_format.printf "%i. @{<bold>%s@}@." (i + 1) label;
  let server_socket = make_socket ~sw ~net 8000 in

  let rec accept i = function
    | [] -> ()
    | test :: rest ->
        Net.accept_fork ~sw ~on_error:ignore server_socket (fun flow _ ->
            Buf_write.with_flow flow @@ fun writer ->
            Reader.run ~sw flow @@ fun next_element ->
            test_runner ~writer ~next_element i test);
        accept (i + 1) rest
  in

  accept 0 tests

let run_server_tests ~sw net =
  Fiber.fork ~sw @@ fun () ->
  Switch.run @@ fun sw ->
  let groups : test_group list =
    [
      {
        label = "Connection-level";
        tests =
          [
            {
              label = "Initialization, preface exchange";
              steps =
                [
                  Expect.magic;
                  Expect.settings;
                  Write.setting;
                  Expect.settings_ack;
                  Write.settings_ack;
                  Write.goaway;
                ];
            };
            {
              label = "Ping-pong";
              steps =
                [
                  Expect.magic;
                  Expect.settings;
                  Write.setting;
                  Expect.settings_ack;
                  Write.settings_ack;
                  Expect.window_update;
                  Write.ping;
                  Expect.ping;
                  Write.goaway;
                ];
            };
          ];
      };
    ]
  in

  groups_runner ~sw ~net groups
