open Event
open H2kit
module W = Writer

type node = Write of (W.t -> unit) | Expect of matcher | Multi of t list
and t = node list

let expect x = Expect x
let ( ?? ) = expect
let write x = Write x
let ( !! ) = write
let multi x = Multi x
let both x y = multi [ x; y ]

type status = NoMatch of (string list * Event.t) | Match
type state = { branch : t; status : status }

let preface =
  [
    expect magic;
    expect (frame_header ~flags:Flags.(default_flags) Settings);
    write W.(settings [] ++ settings ~flags:Flags.(default_flags |> set_ack) []);
  ]

let conn_only =
  preface
  @ [ expect (frame_header ~flags:Flags.(default_flags |> set_ack) Settings) ]

let grace_end =
  [ write W.(goaway NoError); (* expect (goaway_code NoError);*) expect eof ]

let with_preface ?(settings = []) branch continuation =
  [
    expect magic;
    expect (frame_header ~flags:Flags.(default_flags) Settings);
    write (W.settings settings);
    !!W.(settings ~flags:Flags.(default_flags |> set_ack) []);
  ]
  @ [ both [ ??settings_ack ] branch ]
  @ continuation

let runner ~await_event ~writer =
  let rec state_machine ev_opt matched branch =
    match (branch, matched) with
    | Write write :: rest, matched ->
        write writer;
        state_machine ev_opt matched rest
    | Expect check :: rest, false -> (
        let ev = match ev_opt with None -> await_event () | Some ev -> ev in
        match check ev with
        | Ok () -> state_machine None true rest
        | Error expected -> Some { status = NoMatch ([ expected ], ev); branch }
        )
    | Multi [] :: rest, false -> state_machine ev_opt false rest
    | Multi branches :: rest, false ->
        let ev = match ev_opt with None -> await_event () | Some ev -> ev in

        let rec aux expected tried_branches = function
          | current_branch :: tail_branches -> (
              match state_machine (Some ev) false current_branch with
              | Some { status = Match; branch = new_branch } ->
                  state_machine None false
                    (Multi (tried_branches @ (new_branch :: tail_branches))
                    :: rest)
              | Some { status = NoMatch (expts, _); branch = new_branch } ->
                  aux (expected @ expts)
                    (tried_branches @ [ new_branch ])
                    tail_branches
              | None ->
                  state_machine None false
                    (Multi (tried_branches @ tail_branches) :: rest))
          | [] -> Some { status = NoMatch (expected, ev); branch = [] }
        in

        aux [] [] branches
    | (Expect _ | Multi _) :: _, true -> Some { status = Match; branch }
    | [], _ -> None
  in

  let rec state_loop branch =
    match state_machine None false branch with
    | None -> Ok ()
    | Some { status = Match; branch } -> state_loop branch
    | Some { status = NoMatch info; _ } -> Error info
  in
  state_loop
