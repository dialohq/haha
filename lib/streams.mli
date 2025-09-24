type 'peer t

val init_client : int32 -> Peer.client t
val init_server : request_handler:Reqd.handler -> int32 -> Peer.server t
val update_max_streams : int32 -> 'a t -> 'a t
val active_streams : 'a t -> int
val last_peer_stream : _ t -> int32
(* val count_active : _ t -> int *)
(* val close_stream : ?err:Error.t -> Stream_identifier.t -> 'p t -> 'p t *)
(* val close_all : ?err:Error.t -> _ t -> unit *)
(* val all_closed : _ t -> bool *)
(* val update_closing_streams : 'p t -> 'p t *)

val read_data :
  id:Stream_identifier.t ->
  end_stream:bool ->
  Cstruct.t ->
  'a t ->
  ('a t, Error_code.t * string) result

val receive_headers :
  id:Stream_identifier.t ->
  end_stream:bool ->
  Headers.t ->
  'a t ->
  ('a t, Error_code.t * string) result

val receive_rst :
  id:Stream_identifier.t ->
  Error_code.t ->
  'a t ->
  ('a t, Error_code.t * string) result

(*
val receive_trailers :
  writer:Writer.t ->
  headers:Headers.t ->
  Stream_identifier.t ->
  'p t ->
  ('p t, Error.connection_error) result

val receive_rst :
  error_code:Error_code.t ->
  Stream_identifier.t ->
  'p t ->
  ('p t, Error.connection_error) result

val receive_window_update :
  writer:Writer.t ->
  Stream_identifier.t ->
  int32 ->
  'p t ->
  ('p t, Error.connection_error) result

val receive_response :
  pseudo:Headers.Pseudo.response_pseudos ->
  end_stream:bool ->
  headers:Headers.t ->
  writer:Writer.t ->
  Stream_identifier.t ->
  client_peer t ->
  (client_peer t, Error.connection_error) result

val receive_request :
  writer:Writer.t ->
  request_handler:Reqd.handler ->
  pseudo:Headers.Pseudo.request_pseudos ->
  end_stream:bool ->
  headers:Headers.t ->
  max_streams:int32 ->
  Stream_identifier.t ->
  server_peer t ->
  (server_peer t, Error.connection_error) result

val write_request :
  writer:Writer.t -> request:Request.t -> client_peer t -> client_peer t

val body_writers_transitions :
  writer:Writer.t -> max_frame_size:int -> 'p t -> (unit -> 'p t -> 'p t) list

val response_writers_transitions :
  writer:Writer.t ->
  server_peer t ->
  (unit -> server_peer t -> server_peer t) list
*)
