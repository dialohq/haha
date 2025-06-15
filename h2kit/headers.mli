type t
(** Type representing a set of header fields *)

val of_list : (string * string) list -> t
val to_list : t -> (string * string) list
val find_opt : string -> t -> string option
