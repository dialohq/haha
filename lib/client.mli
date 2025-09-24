val connect :
  ?settings:Settings.t ->
  [> Eio.Flow.two_way_ty ] Eio.Resource.t ->
  Connection.iteration
