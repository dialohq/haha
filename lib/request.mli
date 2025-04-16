open Types

(* 
   1. response handler -> always sync
   w. body_reader - always sync
*)
type response_handler = Response.t -> body_reader

type t = {
  path : string;
  meth : Method.t;
  authority : string option;
  scheme : string;
  headers : Headers.t list;
  body_writer : body_writer option;
  response_handler : response_handler option;
}

type request_writer = unit -> t option

val path : t -> string
val meth : t -> Method.t
val scheme : t -> string
val authority : t -> string option
val headers : t -> Headers.t list

val create :
  ?authority:string ->
  ?scheme:string ->
  response_handler:response_handler ->
  headers:Headers.t list ->
  Method.t ->
  string ->
  t

val create_with_streaming :
  ?authority:string ->
  ?scheme:string ->
  body_writer:body_writer ->
  response_handler:response_handler ->
  headers:Headers.t list ->
  Method.t ->
  string ->
  t

val handle :
  response_writer:(unit -> Response.t) ->
  on_data:body_reader ->
  body_reader * (unit -> Response.t)
