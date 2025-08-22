val connection_handler :
  'context.
  ?config:Settings.t ->
  ?goaway_writer:(unit -> unit) ->
  error_handler:(Error.connection_error -> unit) ->
  Reqd.handler ->
  [> `Flow | `R | `W ] Eio.Resource.t ->
  Eio.Net.Sockaddr.stream ->
  unit
