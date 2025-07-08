open H2kit

type t

val create : writer:Buf_write.t -> hpack:Hpack.Encoder.t -> t

val settings :
  ?flags:Flags.t -> ?len:int -> ?id:int32 -> Settings.setting list -> t -> unit

val unknown_setting : t -> unit
val ping : ?flags:Flags.t -> ?len:int -> ?id:int32 -> string -> t -> unit

val goaway :
  ?flags:Flags.t -> ?len:int -> ?id:int32 -> Error_code.t -> t -> unit

val window_update :
  ?flags:Flags.t -> ?len:int -> ?id:int32 -> int32 -> t -> unit

val headers :
  ?flags:Flags.t ->
  ?len:int ->
  ?id:int32 ->
  ?pad_len:int ->
  [ `List of (string * string) list | `Block of Cstruct.t ] ->
  t ->
  unit

val rst_stream :
  ?flags:Flags.t -> ?len:int -> ?id:int32 -> Error_code.t -> t -> unit

val unknown : t -> unit
