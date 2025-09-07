open Body

type t = { status : Status.t; headers : Headers.t }
type 'context handler = 'context -> t -> 'context reader option * 'context

let create status headers = { status; headers }
let status t = t.status
let headers t = t.headers

let is_final t =
  match t.status with #Status.informational -> false | _ -> true
