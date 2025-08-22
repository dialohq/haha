type test = {
  label : string;
  branch : Branch.t;
  description : (string, Format.formatter, unit, string) format4 option;
  streams : Case.stream list option;
  settings : H2kit.Settings.setting list option;
  ignore : Ignore.t;
}

type test_group = {
  label : string;
  tests : test list;
  streams : Case.stream list;
  settings : H2kit.Settings.setting list;
  ignore : Ignore.t;
}

let test ?settings ?streams ?desc ?(ignore = Ignore.nothing) label branch =
  { label; branch; description = desc; streams; settings; ignore }

let test_group ?(settings = []) ?(streams = []) ?(ignore = Ignore.nothing) label
    tests =
  { label; settings; streams; tests; ignore }

let run_test :
    clock:float Eio.Time.clock_ty Eio.Resource.t ->
    await_event:(unit -> Event.t) ->
    writer:Buf_write.t ->
    float ->
    string ->
    (Event.t -> bool) ->
    test ->
    (unit, string list) result =
 fun ~clock ~await_event:await_ev ~writer:writer' start_time group_label
     group_ignore { branch; label; description; ignore = ign; _ } ->
  let all_events = ref [] in
  let record_event ev = all_events := `Send ev :: !all_events in
  let rec await_event () =
    let ev = await_ev () in
    all_events := `Recv ev :: !all_events;
    if ign ev || group_ignore ev then await_event () else ev
  in
  let writer =
    Writer.create ~writer:writer' ~record_event
      ~hpack:(Hpack.Encoder.create 1000)
  in

  let run = Branch.runner ~await_event ~writer in
  let res = run branch in
  let time = (Eio.Time.now clock -. start_time) *. 1000. in
  begin
    match res with
    | Ok () -> Util.print_success ~group:group_label ~test:label ~time
    | Error expected ->
        let expected = String.concat " OR " expected in
        let reason = Format.asprintf "Expected %s" expected in
        let open H2kit.Serializers.Make (Buf_write) in
        write_goaway_frame ~debug_data:(Cstruct.of_string reason) 0l
          ProtocolError writer';
        Buf_write.flush writer';
        Util.print_failure ~group:group_label ~test:label ~time;

        print_newline ();
        List.iter
          (function
            | `Recv ev ->
                Ocolor_format.printf "  @{<hi_black;it>(recv) %a@}@."
                  Event.pp_hum_short ev
            | `Send ev ->
                Ocolor_format.printf "  @{<hi_black;it>(send) %a@}@."
                  Event.pp_hum_short ev)
          List.(rev !all_events);
        print_newline ();

        Ocolor_format.printf "@{<red>  %s@}@.@." reason;
        Option.iter
          (fun description ->
            let desc =
              Ocolor_format.asprintf "  @{<grey>@{<bold>> %s@}@}@."
                (Ocolor_format.asprintf description)
            in
            Util.print_wrapped_sentence ~indent:6 desc)
          description
  end;
  res

open Eio

let run_groups :
    sw:Switch.t ->
    net:[> _ Net.ty ] Resource.t ->
    clock:float Time.clock_ty Resource.t ->
    int ->
    test_group list ->
    Case.t list =
 fun ~sw ~net ~clock first_port groups ->
  let rec aux results group_i port cases = function
    | [] -> (cases, results)
    | { label; tests; streams; settings; ignore = ign } :: rest ->
        let rec accept :
            _ result Promise.or_exn list ->
            Case.t list ->
            int ->
            test list ->
            int * Case.t list * _ result Promise.or_exn list =
         fun results cases i -> function
           | [] -> (port + i, List.rev cases, results)
           | ({ settings = settings'; streams = streams'; _ } as test) :: rest
             ->
               let server_socket =
                 Net.listen ~sw ~backlog:10 ~reuse_addr:true net
                   (`Tcp (Net.Ipaddr.V4.any, port + i))
               in
               let v =
                 Fiber.fork_promise ~sw (fun () ->
                     let start = Time.now clock in
                     Switch.run @@ fun sw ->
                     let flow, _ = Net.accept ~sw server_socket in
                     Buf_write.with_flow flow @@ fun writer ->
                     Reader.run ~sw ~clock flow @@ fun await_event ->
                     run_test ~clock ~writer ~await_event start label ign test)
               in
               let new_cases =
                 {
                   Case.port = port + i;
                   streams = Option.value ~default:streams streams';
                   settings = Option.value ~default:settings settings';
                 }
                 :: cases
               in
               accept (v :: results) new_cases (i + 1) rest
        in
        let next_port, cases', new_results = accept [] [] 0 tests in
        aux (results @ new_results) (group_i + 1) next_port
          (List.concat [ cases; cases' ])
          rest
  in
  let cases, results = aux [] 1 first_port [] groups in

  Fiber.fork ~sw (fun () ->
      let rec auxx succ fail = function
        | [] ->
            print_newline ();
            Ocolor_format.printf "|============================|@.";
            Ocolor_format.printf
              "|        @{<green;bold>%i@}/%i Passed        |@." succ
              (succ + fail);
            Ocolor_format.printf "|============================|@.";
            print_newline ()
        | p :: rest -> (
            match Promise.await_exn p with
            | Ok _ -> auxx (succ + 1) fail rest
            | Error _ -> auxx succ (fail + 1) rest)
      in

      auxx 0 0 results);

  cases
