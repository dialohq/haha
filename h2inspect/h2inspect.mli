val run_server_tests :
  sw:Eio.Switch.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  [> [ `Generic | `Unix ] Eio.Net.ty ] Eio.Resource.t ->
  unit
