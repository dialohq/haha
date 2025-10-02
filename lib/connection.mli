type 'a t

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

type 'a iteration_base =
  [> `End
  | `Error of Error.connection_error
  | `Shutdown of unit -> 'a iteration_base ]
  as
  'a

type ('p, 'a) in_progress_f =
  'p Streams.t ->
  (bool -> 'p Streams.t -> Writer.write list -> 'a iteration_base) ->
  'a iteration_base

val start : ('a, 'b) in_progress_f -> 'a t -> 'b iteration_base

val handle_preface_error :
  Writer.t -> Error.connection_error -> 'a iteration_base
