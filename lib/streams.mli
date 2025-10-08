type 'peer t

val init_client : int32 -> int32 -> Peer.client t

val init_server :
  request_handler:Reqd.handler -> int32 -> int32 -> Peer.server t

val update_local_max : int32 -> 'a t -> 'a t
val update_peer_max : int32 -> 'a t -> 'a t
val active_streams : 'a t -> int
val last_peer_stream : _ t -> int32

val write_request :
  request:Request.t -> Peer.client t -> Peer.client t * Writer.write list

val read_data :
  id:Stream_identifier.t ->
  end_stream:bool ->
  Cstruct.t ->
  'a t ->
  ('a t * Writer.write list, Error_code.t * string) result

val receive_headers :
  id:Stream_identifier.t ->
  end_stream:bool ->
  Headers.t ->
  'a t ->
  ('a t * Writer.write list, Error_code.t * string) result

val receive_rst :
  id:Stream_identifier.t ->
  Error_code.t ->
  'a t ->
  ('a t * Writer.write list, Error_code.t * string) result

val get_events : 'a t -> (unit -> 'a t -> 'a t * Writer.write list) list
