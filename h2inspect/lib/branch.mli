type node
and t = node list

(* {2 Node makers } *)

val many_match :
  'a Event.matcher ->
  ('a list -> [ `Done | `More | `NoMatch of string ]) ->
  node

val many : 'a Event.matcher -> node
val single : 'a Event.matcher -> node
val ( ?? ) : 'a Event.matcher -> node
val write : (Writer.t -> unit) -> node
val ( !! ) : (Writer.t -> unit) -> node
val multi : t list -> node
val both : t -> t -> node

(* {2 Predefined branches } *)

val preface : t
val conn_only : t
val grace_end : t

val with_preface :
  ?settings:H2kit.Settings.setting list -> t -> node list -> node list

val runner :
  await_event:(unit -> Event.t) ->
  writer:Writer.t ->
  t ->
  (unit, string list * Event.t) result
