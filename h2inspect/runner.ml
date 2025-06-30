module BWrite = Buf_write
open Eio
open Steps
open H2kit
open Format

let print_wrapped_sentence ~indent sentence =
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

type state = { ignore : Element.t -> bool }

type test = {
  label : string;
  steps : step list;
  description : (string, Format.formatter, unit, string) format4 option;
}

type test_group = { label : string; tests : test list }

let initial_state = { ignore = Ignore.deafult }

let expect_transition :
    next_element:(unit -> Element.t) ->
    expect_step ->
    state ->
    (state, string) result =
 fun ~next_element expect ({ ignore } as state) ->
  let el = next_element () in
  match (expect el, ignore el) with
  | None, _ | Some _, true -> Ok state
  | Some msg, false -> Error msg

let write_transition :
    writer:Buf_write.t -> write_step -> state -> (state, _) result =
 fun ~writer write state ->
  write writer;
  Ok state

let ignore_transition : ignore_step -> state -> (state, _) result =
 fun new_ignore { ignore } ->
  match new_ignore with
  | Add new_ignore -> Ok { ignore = Ignore.(ignore + new_ignore) }
  | Reset -> Ok { ignore = Ignore.deafult }

let transition :
    next_element:(unit -> Element.t) ->
    writer:Buf_write.t ->
    state ->
    step ->
    (state, string) result =
 fun ~next_element ~writer state -> function
  | Expect e -> expect_transition ~next_element e state
  | Write w -> write_transition ~writer w state
  | Ignore i -> ignore_transition i state

let run_test :
    next_element:(unit -> Element.t) ->
    writer:Buf_write.t ->
    int ->
    test ->
    unit =
 fun ~next_element ~writer i { steps; label; description } ->
  Ocolor_format.printf "  %i. @{<grey>%s@}%!" (i + 1) label;

  let rec fold_state : state -> step list -> string option =
   fun state -> function
     | [] -> None
     | x :: rest -> (
         match transition ~next_element ~writer state x with
         | Ok state -> fold_state state rest
         | Error msg -> Some msg)
  in

  match fold_state initial_state steps with
  | None -> Ocolor_format.printf " - @{<green>@{<bold>Pass@}@}@."
  | Some msg ->
      let open Serializers.Make (BWrite) in
      write_goaway_frame ~debug_data:(Cstruct.of_string msg) writer 0l
        ProtocolError;
      Buf_write.flush writer;
      Ocolor_format.printf " - @{<red>@{<bold>Fail:@} %s@}@." msg;
      description
      |> Option.iter @@ fun description ->
         let desc =
           Ocolor_format.asprintf "    @{<grey>@{<bold>> %s@}@}@."
             (Ocolor_format.asprintf description)
         in
         print_wrapped_sentence ~indent:6 desc

let run_groups :
    sw:Switch.t -> net:[> _ Net.ty ] Resource.t -> test_group list -> unit =
 fun ~sw ~net ->
  List.iteri @@ fun i { label; tests } ->
  Ocolor_format.printf "%i. @{<bold>%s@}@." (i + 1) label;
  let server_socket =
    Net.listen ~sw ~backlog:10 ~reuse_addr:true net
      (`Tcp (Net.Ipaddr.V4.any, 8000))
  in

  let rec accept i = function
    | [] -> ()
    | test :: rest ->
        Net.accept_fork ~sw ~on_error:ignore server_socket (fun flow _ ->
            Buf_write.with_flow flow @@ fun writer ->
            Reader.run ~sw flow @@ fun next_element ->
            run_test ~writer ~next_element i test);
        accept (i + 1) rest
  in

  accept 0 tests
