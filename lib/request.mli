open Types

(* 
   1. response handler -> always sync
   w. body_reader - always sync
*)
type 'context response_handler = 'context Response.t -> 'context body_reader

type 'context t = {
  path : string;
  meth : Method.t;
  authority : string option;
  scheme : string;
  headers : Headers.t list;
  body_writer : 'context body_writer option;
  response_handler : 'context response_handler option;
  error_handler : Error_code.t -> unit;
  initial_context : 'context;
}

type 'context request_writer = unit -> 'context t option

val path : 'context t -> string
val meth : 'context t -> Method.t
val scheme : 'context t -> string
val authority : 'context t -> string option
val headers : 'context t -> Headers.t list

val create :
  ?authority:string ->
  ?scheme:string ->
  context:'context ->
  response_handler:'context response_handler ->
  error_handler:(Error_code.t -> unit) ->
  headers:Headers.t list ->
  Method.t ->
  string ->
  'context t

val create_with_streaming :
  ?authority:string ->
  ?scheme:string ->
  context:'context ->
  body_writer:'context body_writer ->
  response_handler:'context response_handler ->
  error_handler:(Error_code.t -> unit) ->
  headers:Headers.t list ->
  Method.t ->
  string ->
  'context t

val handle :
  context:'context ->
  response_writer:(unit -> 'context Response.t) ->
  error_handler:(Error_code.t -> unit) ->
  on_data:'context body_reader ->
  'context body_reader
  * (unit -> 'context Response.t)
  * (Error_code.t -> unit)
  * 'context
