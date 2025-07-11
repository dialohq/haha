let print_wrapped_sentence ~indent sentence =
  let open Format in
  set_margin 100;

  pp_open_hovbox std_formatter indent;

  let words = String.split_on_char ' ' sentence in

  List.iter
    (fun word ->
      pp_print_string std_formatter word;
      pp_print_space std_formatter ())
    words;

  pp_close_box std_formatter ();
  pp_print_newline std_formatter ()

type test = {
  label : string;
  spec : unit Spec.t;
  description : (string, Format.formatter, unit, string) format4 option;
  streams : Case.stream list option;
  settings : H2kit.Settings.setting list option;
}

type test_group = {
  label : string;
  tests : test list;
  streams : Case.stream list;
  settings : H2kit.Settings.setting list;
}

let test ?settings ?streams ?desc label spec =
  { label; spec; description = desc; streams; settings }

let test_group ?(settings = []) ?(streams = []) label tests =
  { label; settings; streams; tests }

let run_test :
    next_element:(unit -> Element.t) ->
    writer:Buf_write.t ->
    int ->
    int ->
    test ->
    unit =
 fun ~next_element ~writer:writer' j i { spec; label; description; _ } ->
  let writer =
    Writer.create ~writer:writer' ~hpack:(Hpack.Encoder.create 1000)
  in
  let state = Spec.make_state ~next_element ~writer in
  match
    try
      spec state;
      None
    with Spec.Fail msg -> Some msg
  with
  | None ->
      Ocolor_format.printf "%i.%i. @{<grey>%s@} - @{<green>@{<bold>Pass@}@}@." j
        (i + 1) label
  | Some msg ->
      let open H2kit.Serializers.Make (Buf_write) in
      write_goaway_frame ~debug_data:(Cstruct.of_string msg) 0l ProtocolError
        writer';
      Buf_write.flush writer';
      Ocolor_format.printf "%i.%i. @{<grey>%s@} - @{<red>@{<bold>Fail:@} %s@}@."
        j (i + 1) label msg;
      description
      |> Option.iter @@ fun description ->
         let desc =
           Ocolor_format.asprintf "  @{<grey>@{<bold>> %s@}@}@."
             (Ocolor_format.asprintf description)
         in
         print_wrapped_sentence ~indent:6 desc

open Eio

let run_groups :
    sw:Switch.t ->
    net:[> _ Net.ty ] Resource.t ->
    clock:float Time.clock_ty Resource.t ->
    int ->
    test_group list ->
    Case.t list =
 fun ~sw ~net ~clock first_port ->
  let rec aux group_i port cases = function
    | [] -> cases
    | { label = _; tests; streams; settings } :: rest ->
        let rec accept : Case.t list -> int -> test list -> int * Case.t list =
         fun cases i -> function
           | [] -> (port + i, List.rev cases)
           | ({ settings = settings'; streams = streams'; _ } as test) :: rest
             ->
               let server_socket =
                 Net.listen ~sw ~backlog:10 ~reuse_addr:true net
                   (`Tcp (Net.Ipaddr.V4.any, port + i))
               in
               Fiber.fork ~sw (fun () ->
                   Switch.run @@ fun sw ->
                   Net.accept_fork ~sw ~on_error:ignore server_socket
                   @@ fun flow _ ->
                   Buf_write.with_flow flow @@ fun writer ->
                   Reader.run ~sw ~clock flow @@ fun next_element ->
                   run_test ~writer ~next_element group_i i test);
               let json_l =
                 {
                   Case.port = port + i;
                   streams = Option.value ~default:streams streams';
                   settings = Option.value ~default:settings settings';
                 }
                 :: cases
               in
               accept json_l (i + 1) rest
        in
        let next_port, cases' = accept [] 0 tests in
        aux (group_i + 1) next_port (List.concat [ cases; cases' ]) rest
  in
  aux 1 first_port []
