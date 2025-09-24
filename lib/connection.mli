type 'a t

type iteration =
  | End
  | Error of Error.connection_error
  | InProgress of (unit -> iteration)

val initial_client :
  writer:Writer.t ->
  reader:Reader.t ->
  Settings.t ->
  Settings.setting list ->
  Peer.client t

val initial_server :
  writer:Writer.t ->
  reader:Reader.t ->
  request_handler:Reqd.handler ->
  Settings.t ->
  Settings.setting list ->
  Peer.server t

val start : ('a t, Error.connection_error) result -> iteration
