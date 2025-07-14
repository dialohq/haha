type node
and t = node list

(* {2 Node makers } *)

val expect : Event.matcher -> node
val ( ?? ) : Event.matcher -> node
val write : (Writer.t -> unit) -> node
val ( !! ) : (Writer.t -> unit) -> node
val multi : t list -> node
val both : t -> t -> node

(* {2 Predefined branches } *)

val preface : t
val conn_only : t
val grace_end : t
val with_preface : t -> node list -> node list

val runner :
  await_event:(unit -> Event.t) ->
  writer:Writer.t ->
  t ->
  (unit, string list * Event.t) result
