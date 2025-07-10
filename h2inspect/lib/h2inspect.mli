module Case : sig
  type action = GET of string | POST of string
  type case = { port : int; scenerio : action list }

  val yojson_of_cases : case list -> Yojson.Safe.t
end

val run_server_tests :
  ?first_port:int ->
  sw:Eio.Switch.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  [> [ `Generic | `Unix ] Eio.Net.ty ] Eio.Resource.t ->
  Case.case list
