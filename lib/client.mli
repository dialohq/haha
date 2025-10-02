type iteration =
  [ `End
  | `Error of Error.connection_error
  | `Shutdown of unit -> iteration
  | `InProgress of ?shutdown:bool -> Request.t list -> iteration ]

val connect :
  ?settings:Settings.t -> [> Eio.Flow.two_way_ty ] Eio.Resource.t -> iteration
