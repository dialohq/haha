type state = (Streams.client_readers, Streams.client_writer) State.t
type step = (Streams.client_readers, Streams.client_writer) Runtime.step

val run :
  ?debug:bool ->
  ?config:Settings.t ->
  request_writer:Request.request_writer ->
  [> `Flow | `R | `W ] Eio.Resource.t ->
  step * (state -> step)
