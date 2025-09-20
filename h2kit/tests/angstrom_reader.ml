open Angstrom

type 'a t = 'a Angstrom.t

let uint8 = any_int8
let string s = string s >>| ignore
let return = return
let skip = advance
let ( <* ) = ( <* )
let ( *> ) = ( *> )

module BE = struct
  let uint16 = BE.any_int16
  let uint32 = BE.any_int32
end

let bind t f = bind t ~f
let map f t = map t ~f
let pair t1 t2 = lift2 (fun x y -> (x, y)) t1 t2

let unsafe_take_bigarray n =
  Unsafe.take n (fun ba ~off ~len -> Bigstringaf.sub ba ~off ~len)
