type t
(** Type representing a set of header fields *)

val of_list : (string * string) list -> t
val to_list : t -> (string * string) list
val iter : (string * string -> unit) -> t -> unit
val find_opt : string -> t -> string option
val make_response_headers : ?extra:(string * string) list -> int -> t

module Pseudo : sig
  type request_pseudos = {
    meth : string;
    scheme : string;
    path : string;
    authority : string option;
  }

  type response_pseudos = { status : string }
  type pseudo = Request of request_pseudos | Response of response_pseudos
  type validation_result = NotPresent | Valid of pseudo | Invalid of string

  val validate : t -> validation_result
end
