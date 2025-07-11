open H2kit

type test
type test_group

val test :
  ?settings:Settings.setting list ->
  ?streams:Case.stream list ->
  ?desc:(string, Format.formatter, unit, string) format4 ->
  string ->
  unit Spec.t ->
  test

val test_group :
  ?settings:Settings.setting list ->
  ?streams:Case.stream list ->
  string ->
  test list ->
  test_group

val run_groups :
  sw:Eio.Switch.t ->
  net:[> [ `Generic | `Unix ] Eio.Net.ty ] Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  int ->
  test_group list ->
  Case.t list
