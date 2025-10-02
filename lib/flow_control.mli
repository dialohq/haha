type t

val initial_increment : int32
val initial : t
val receive_data : id:Stream_identifier.t -> int32 -> t -> t * Writer.write list
val incr_out_flow : t -> int32 -> t
val incr_sent : t -> int32 -> initial_window_size:int32 -> (t, unit) result
val pp_hum : Format.formatter -> t -> unit
