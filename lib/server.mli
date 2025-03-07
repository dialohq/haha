(* type header = string * string *)
(* type meth = GET | POST *)
(* type request = { *)
(*   headers : header list; *)
(*   path : string; *)
(*   meth : meth; *)
(*   reader : Cstruct.t Eio.Stream.t; *)
(*   writer : Cstruct.t -> unit; *)
(* } *)
(* type state *)
(* type connection = { state : state } *)
(* val handle_requests : connection -> (request -> unit) -> unit *)
(**)
val listen :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  Bigstringaf.t Eio.Stream.t ->
  [> [> `Generic ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  unit
