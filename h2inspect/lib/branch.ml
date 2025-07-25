open Event
open H2kit
module W = Writer

type 'a matcher_node = {
  matcher : 'a matcher;
  matched : 'a list;
  is_done : ('a list -> [ `Done | `More | `NoMatch of string ]) option;
}

type node =
  | Matcher : 'a matcher_node -> node
  | Write of (W.t -> unit)
  | Multi of t list

and t = node list

let many_match matcher is_done =
  Matcher { matcher; is_done = Some is_done; matched = [] }

let many matcher = Matcher { matcher; is_done = None; matched = [] }

let single matcher =
  many_match matcher (fun l -> if List.length l > 0 then `Done else `More)

let ( ?? ) = single
let write x = Write x
let ( !! ) = write
let multi x = Multi x
let both x y = multi [ x; y ]

type resolved = NoMatch of string list | Match
type state = { branch : t; resolution : resolved }

let preface =
  [
    single magic;
    single (frame_header ~flags:Flags.(default_flags) Settings);
    write W.(settings [] ++ settings ~flags:Flags.(default_flags |> set_ack) []);
  ]

let conn_only =
  preface
  @ [ single (frame_header ~flags:Flags.(default_flags |> set_ack) Settings) ]

let grace_end =
  [ write W.(goaway NoError); (* expect (goaway_code NoError);*) single eof ]

let with_preface ?(settings = []) branch continuation =
  [
    single magic;
    single (frame_header ~flags:Flags.(default_flags) Settings);
    write (W.settings settings);
    !!W.(settings ~flags:Flags.(default_flags |> set_ack) []);
  ]
  @ [ both [ ??settings_ack ] branch ]
  @ continuation

let runner ~await_event ~writer =
  let rec state_machine ev_opt did_matched branch =
    match (branch, did_matched) with
    | Write write :: rest, matched ->
        write writer;
        state_machine ev_opt matched rest
    | Matcher ({ matcher; is_done; matched } as node) :: rest, false -> begin
        let ev = match ev_opt with None -> await_event () | Some ev -> ev in

        match (matcher ev, is_done) with
        | Ok m, None ->
            state_machine None true
              (Matcher { node with matched = m :: matched } :: rest)
        | Error _, None -> state_machine (Some ev) true rest
        | Ok m, Some is_done -> begin
            match is_done List.(rev (m :: matched)) with
            | `Done -> state_machine None true rest
            | `More ->
                state_machine None true
                  (Matcher { node with matched = m :: matched } :: rest)
            | `NoMatch expected ->
                Some { resolution = NoMatch [ expected ]; branch }
          end
        | Error expected, Some is_done -> begin
            match is_done List.(rev matched) with
            | `Done -> state_machine (Some ev) true rest
            | `More -> Some { resolution = NoMatch [ expected ]; branch }
            | `NoMatch expected ->
                Some { resolution = NoMatch [ expected ]; branch }
          end
      end
    | Multi [] :: rest, false -> state_machine ev_opt false rest
    | Multi branches :: rest, false ->
        let ev = match ev_opt with None -> await_event () | Some ev -> ev in

        let rec aux expected tried_branches = function
          | current_branch :: tail_branches -> (
              match state_machine (Some ev) false current_branch with
              | Some { resolution = Match; branch = new_branch } ->
                  state_machine None false
                    (Multi (tried_branches @ (new_branch :: tail_branches))
                    :: rest)
              | Some { resolution = NoMatch expts; branch = new_branch } ->
                  aux (expected @ expts)
                    (tried_branches @ [ new_branch ])
                    tail_branches
              | None ->
                  state_machine None false
                    (Multi (tried_branches @ tail_branches) :: rest))
          | [] -> Some { resolution = NoMatch expected; branch = [] }
        in

        aux [] [] branches
    | (Matcher _ | Multi _) :: _, true -> Some { resolution = Match; branch }
    | [], _ -> None
  in

  let rec state_loop branch =
    match state_machine None false branch with
    | None -> Ok ()
    | Some { resolution = Match; branch } -> state_loop branch
    | Some { resolution = NoMatch info; _ } -> Error info
  in
  state_loop
