type t
type writer = t -> unit
type _ Effect.t += Write : writer -> unit Effect.t

val write : writer -> unit
val create : header_table_size:int -> int -> t
val set_encoder_capacity : t -> int -> unit
val flush : t -> [> Eio.Flow.sink_ty ] Eio.Resource.t -> (unit, exn) result
val connection_preface : t -> unit

val goaway :
  ?debug_data:Cstruct.t -> Stream_identifier.t -> Error_code.t -> t -> unit

val window_update : increment:int32 -> Stream_identifier.t -> t -> unit
val settings : Settings.t -> t -> unit
val settings_ack : t -> unit
val ping : ?ack:bool -> Cstruct.t -> t -> unit

val data :
  ?padding_length:int ->
  ?end_stream:bool ->
  Stream_identifier.t ->
  Cstruct.t list ->
  t ->
  unit

val response_headers :
  ?padding_length:int ->
  ?end_header:bool ->
  Stream_identifier.t ->
  _ Response.t ->
  t ->
  unit

val request_headers :
  ?padding_length:int ->
  ?end_header:bool ->
  Stream_identifier.t ->
  Request.t ->
  t ->
  unit

val trailers :
  ?padding_length:int ->
  ?end_header:bool ->
  Stream_identifier.t ->
  Headers.t ->
  t ->
  unit

val rst_stream : Stream_identifier.t -> Error_code.t -> t -> unit
val pp_hum : Format.formatter -> t -> unit
