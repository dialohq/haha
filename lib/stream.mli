type 'a t
type 'p transition = 'p t -> ('p t, Error_code.t * string) result

val create_idle : id:Stream_identifier.t -> 'a t
val create_terminated : id:Stream_identifier.t -> 'a t
val read_data : end_stream:bool -> Cstruct.t -> 'a transition
val is_active : 'a t -> bool

val receive_headers_client :
  end_stream:bool -> Headers.t -> Peer.client transition

val receive_headers_server :
  request_handler:Reqd.handler ->
  end_stream:bool ->
  Headers.t ->
  Peer.server transition

val receive_rst : Error_code.t -> 'a transition
