open Angstrom

val parse_frame : (Frame.t, Error.t) result t
(** Parser for HTTP/2 frames *)

val connection_preface : string t
(** Parser for magic string of the client's connection preface *)
