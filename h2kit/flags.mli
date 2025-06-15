type t

val default_flags : t
val test_end_stream : t -> bool
val set_end_stream : t -> t
val test_ack : t -> bool
val set_ack : t -> t
val test_end_header : t -> bool
val set_end_header : t -> t
val test_padded : t -> bool
val set_padded : t -> t
val test_priority : t -> bool

val create :
  ?end_stream:bool -> ?end_header:bool -> ?ack:bool -> ?padded:bool -> unit -> t

val of_int : int -> t
val to_int : t -> int
