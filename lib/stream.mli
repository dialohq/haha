type client_peer
type server_peer
type 'a t
type 'p transition = 'p t -> ('p t, Error_code.t * string) result

val create_idle : id:Stream_identifier.t -> 'a t
val create_terminated : id:Stream_identifier.t -> 'a t
val read_data : end_stream:bool -> Cstruct.t -> 'a transition

val receive_headers_client :
  end_stream:bool -> Headers.t -> client_peer transition

val receive_headers_server :
  request_handler:Reqd.handler ->
  end_stream:bool ->
  Headers.t ->
  server_peer transition
