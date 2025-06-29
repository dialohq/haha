type t = int [@@deriving show, eq]

let[@inline] test_bit x i = x land (1 lsl i) <> 0
let[@inline] set_bit x i = x lor (1 lsl i)
let default_flags = 0x0
let test_empty x = x = 0x0
let test_end_stream x = test_bit x 0
let set_end_stream x = set_bit x 0
let test_ack x = test_bit x 0
let set_ack x = set_bit x 0
let test_end_header x = test_bit x 2
let set_end_header x = set_bit x 2
let test_padded x = test_bit x 3
let set_padded x = set_bit x 3
let test_priority x = test_bit x 5

let create ?(end_stream = false) ?(end_header = false) ?(ack = false)
    ?(padded = false) () =
  let flags = default_flags in
  let flags = if end_stream then set_end_stream flags else flags in
  let flags = if end_header then set_end_header flags else flags in
  let flags = if ack then set_ack flags else flags in
  let flags = if padded then set_padded flags else flags in
  flags

let of_int x = x
let to_int x = x
