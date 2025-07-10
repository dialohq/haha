include Eio.Buf_write

let write_uint8 = uint8
let write_string = string

let schedule_bigstring t ?off ?len bs =
  let cs = Cstruct.of_bigarray bs ?off ?len in
  schedule_cstruct t cs

module BE = struct
  include BE

  let write_uint32 = uint32
  let write_uint16 = uint16
end
