type 'context state =
  ( 'context Streams.client_readers,
    'context Streams.client_writer,
    'context )
  State.t

type 'context step =
  ( 'context Streams.client_readers,
    'context Streams.client_writer,
    'context )
  Runtime.step

val run :
  'c.
  ?debug:bool ->
  ?config:Settings.t ->
  request_writer:'c Request.request_writer ->
  [> `Flow | `R | `W ] Eio.Resource.t ->
  'c step * ('c state -> 'c step)
