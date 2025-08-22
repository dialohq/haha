type t

val create : header_table_size:int -> int -> t
val set_encoder_capacity : t -> int -> unit
val flush : t -> [> Eio.Flow.sink_ty ] Eio.Resource.t -> (unit, exn) result
val connection_preface : t -> unit

val goaway :
  ?debug_data:Cstruct.t -> t -> Stream_identifier.t -> Error_code.t -> unit

val window_update : t -> increment:int32 -> Stream_identifier.t -> unit
val settings : t -> Settings.t -> unit
val settings_ack : t -> unit
val ping : ?ack:bool -> t -> Cstruct.t -> unit

val data :
  ?padding_length:int ->
  ?end_stream:bool ->
  t ->
  Stream_identifier.t ->
  Cstruct.t list ->
  unit

val response_headers :
  ?padding_length:int ->
  ?end_header:bool ->
  t ->
  Stream_identifier.t ->
  _ Response.t ->
  unit

val request_headers :
  ?padding_length:int ->
  ?end_header:bool ->
  t ->
  Stream_identifier.t ->
  Request.t ->
  unit

val trailers :
  ?padding_length:int ->
  ?end_header:bool ->
  t ->
  Stream_identifier.t ->
  Headers.t ->
  unit

val rst_stream : t -> Stream_identifier.t -> Error_code.t -> unit
val pp_hum : Format.formatter -> t -> unit
