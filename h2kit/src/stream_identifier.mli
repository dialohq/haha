type t = int32 [@@deriving show, eq]

val ( === ) : t -> t -> bool
val connection : t
val is_connection : t -> bool
val is_client : t -> bool
val is_server : t -> bool
