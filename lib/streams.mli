module StreamMap : Map.S

type client_peer = private Client
type server_peer = private Server

type (_, 'c) writers =
  | BodyWriter : 'c Body.writer -> ('peer, 'c) writers
  | WritingResponse : 'c Response.response_writer -> (server_peer, 'c) writers

type (_, 'c) readers =
  | BodyReader : 'c Body.reader -> ('peer, 'c) readers
  | AwaitingResponse : 'c Response.handler -> (client_peer, 'c) readers

module Stream : sig
  type ('peer, 'c) open_state
  type ('peer, 'c) half_closed
  type 'context reserved

  type ('peer, 'c) state =
    | Idle
    | Reserved of 'c reserved
    | Open of ('peer, 'c) open_state
    | HalfClosed of ('peer, 'c) half_closed
    | Closed

  type 'peer t = State : ('peer, _) state -> 'peer t
end

type 'peer t

val last_peer_stream : _ t -> int32
val get_next_id : 'a t -> [< `Client | `Server ] -> int32
val initial : unit -> _ t
val count_active : _ t -> int
val close_stream : ?err:Error.t -> Stream_identifier.t -> 'p t -> 'p t
val close_all : ?err:Error.t -> _ t -> unit
val find_stream : Stream_identifier.t -> 'p t -> 'p Stream.t
val all_closed : _ t -> bool

val read_data :
  end_stream:bool ->
  send_update:(int32 -> unit) ->
  data:Bigstringaf.t ->
  Stream_identifier.t ->
  'p t ->
  ('p t, Error.connection_error) result

val receive_trailers :
  headers:Header.t list ->
  Stream_identifier.t ->
  'p t ->
  ('p t, Error.connection_error) result

val receive_rst :
  error_code:Error_code.t ->
  Stream_identifier.t ->
  'p t ->
  ('p t, Error.connection_error) result

val receive_window_update :
  Stream_identifier.t -> int32 -> 'p t -> ('p t, Error.connection_error) result

val receive_response :
  pseudo:Header.Pseudo.response_pseudo ->
  end_stream:bool ->
  headers:Header.t list ->
  writer:Writer.t ->
  Stream_identifier.t ->
  client_peer t ->
  (client_peer t, Error.connection_error) result

val write_request :
  writer:Writer.t -> request:Request.t -> client_peer t -> client_peer t

val body_writers_transitions :
  writer:Writer.t -> max_frame_size:int -> 'p t -> (unit -> 'p t -> 'p t) list
