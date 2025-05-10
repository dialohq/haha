val run :
  ?debug:bool ->
  ?config:Settings.t ->
  request_writer:Request.request_writer ->
  error_handler:(Error.connection_error -> unit) ->
  [> `Flow | `R | `W ] Eio.Resource.t ->
  unit
