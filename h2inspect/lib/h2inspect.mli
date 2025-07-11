module Case : sig
  type stream = GET of string | POST of (string * int)

  type t = {
    port : int;
    settings : H2kit.Settings.setting list;
    streams : stream list;
  }

  val yojson_of_cases : t list -> Yojson.Safe.t
end

val run_server_tests :
  ?first_port:int ->
  sw:Eio.Switch.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  [> [ `Generic | `Unix ] Eio.Net.ty ] Eio.Resource.t ->
  Case.t list
