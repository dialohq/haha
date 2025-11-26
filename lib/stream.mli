type 'a t

type 'p transition =
  'p t -> ('p t * Writer.write list, Error_code.t * string) result

val create_idle : id:Stream_identifier.t -> 'a t
val create_terminated : id:Stream_identifier.t -> 'a t
val is_active : 'a t -> bool
val is_eraseable : 'a t -> bool

val init :
  request:Request.t -> Stream_identifier.t -> Peer.client t * Writer.write list

val read_data : end_stream:bool -> Cstruct.t -> 'a transition

val receive_headers_client :
  end_stream:bool -> Headers.t -> Peer.client transition

val receive_headers_server :
  request_handler:Reqd.handler ->
  end_stream:bool ->
  Headers.t ->
  Peer.server transition

val receive_rst : Error_code.t -> 'a transition
val get_event : 'p t -> (unit -> 'p t -> 'p t * Writer.write list) option
