type continue

val magic_parse :
  Bigstringaf.t -> off:int -> len:int -> (int, Error.connection_error) result

val parse_frame :
  Cstruct.t ->
  continue option ->
  [> `Complete of int * Frame.t
  | `Fail of int * Error.t
  | `Partial of int * continue ]

val read_frames :
  Cstruct.t ->
  continue option ->
  (int * Frame.t list * continue option, int * Error.t) result
