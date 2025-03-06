let[@inline] test_bit_int32 x i =
  let open Int32 in
  not (equal (logand x (shift_left 1l i)) 0l)

let[@inline] test_bit x i = x land (1 lsl i) <> 0
let[@inline] set_bit x i = x lor (1 lsl i)

let[@inline] set_bit_int32 x i =
  let open Int32 in
  logor x (shift_left 1l i)

let[@inline] clear_bit x i = x land lnot (1 lsl i)

let[@inline] clear_bit_int32 x i =
  let open Int32 in
  logand x (lognot (shift_left 1l i))
