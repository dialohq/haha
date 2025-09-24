type t

val create : [> Eio.Flow.source_ty ] Eio.Resource.t -> int -> t
val update_size : int -> t -> t
val read_preface : t -> (unit, Error.t) result
val read_frame : t -> (Frame.t, Error.t) result

val ( >>= ) :
  (t -> ('a, Error.t) result) ->
  (t -> ('b, Error.t) result) ->
  t ->
  ('b, Error.t) result
