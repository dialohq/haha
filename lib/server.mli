val handle :
  ?settings:Settings.t ->
  request_handler:Reqd.handler ->
  [> Eio.Flow.two_way_ty ] Eio.Resource.t ->
  Connection.iteration

val connection_handler :
  ?settings:Settings.t ->
  error_handler:(Error.connection_error -> unit) ->
  Reqd.handler ->
  [> [> `Generic ] Eio.Net.stream_socket_ty ] Eio.Net.connection_handler
