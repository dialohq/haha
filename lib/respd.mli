type t
type handler = t -> Body.reader option

val create : Status.t -> Headers.t -> t
val status : t -> Status.t
val headers : t -> Headers.t
val is_final : t -> bool
