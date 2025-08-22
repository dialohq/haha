type iter_input = Shutdown | Request of Request.t
type iteration = iter_input Types.iteration

val connect :
  'context.
  ?config:Settings.t -> [> `Flow | `R | `W ] Eio.Resource.t -> iteration
