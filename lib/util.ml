let[@inline] test_bit_int32 x i =
  let open Int32 in
  not (equal (logand x (shift_left 1l i)) 0l)

let[@inline] test_bit x i = x land (1 lsl i) <> 0
let[@inline] set_bit x i = x lor (1 lsl i)
let[@inline] clear_bit x i = x land lnot (1 lsl i)

let[@inline] clear_bit_int32 x i =
  let open Int32 in
  logand x (lognot (shift_left 1l i))

let split_cstructs cstructs max_bytes =
  let rec build_group remaining current_group current_size max_bytes =
    if current_size = max_bytes then (List.rev current_group, remaining)
    else
      match remaining with
      | [] -> (List.rev current_group, [])
      | c :: rest ->
          let len = Cstruct.length c in
          if len <= max_bytes - current_size then
            build_group rest (c :: current_group) (current_size + len) max_bytes
          else
            let take = max_bytes - current_size in
            let s1 = Cstruct.sub c 0 take in
            let s2 = Cstruct.sub c take (len - take) in
            (List.rev (s1 :: current_group), s2 :: rest)
  in
  let rec build_all_groups remaining =
    if remaining = [] then []
    else
      let group, new_remaining = build_group remaining [] 0 max_bytes in
      group :: build_all_groups new_remaining
  in
  build_all_groups cstructs

let merge_thunks f1 f2 : unit -> unit =
 fun () ->
  f1 ();
  f2 ()
