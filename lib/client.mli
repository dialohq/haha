val run :
  ?debug:bool ->
  error_handler:(Error.t -> unit) ->
  request_writer:Request.request_writer ->
  Settings.t ->
  [> `Flow | `R | `W ] Eio.Resource.t ->
  unit
