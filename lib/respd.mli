type t
type 'context handler = 'context -> t -> 'context Body.reader option * 'context

val create : Status.t -> Headers.t -> t
val status : t -> Status.t
val headers : t -> Headers.t
val is_final : t -> bool
