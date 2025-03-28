open Types

type final_response = {
  status : Status.t;
  headers : Headers.t list;
  body_writer : body_writer option;
}

type interim_response = {
  status : Status.informational;
  headers : Headers.t list;
}

type t = [ `Interim of interim_response | `Final of final_response ]
type response_writer = unit -> t

let status (t : t) =
  match t with `Interim r -> (r.status :> Status.t) | `Final r -> r.status

let headers (t : t) =
  match t with `Interim r -> r.headers | `Final r -> r.headers

let create (status : Status.t) (headers : Headers.t list) : final_response =
  { status; headers; body_writer = None }

let create_with_streaming ~(body_writer : body_writer) (status : Status.t)
    (headers : Headers.t list) : final_response =
  { status; headers; body_writer = Some body_writer }

let create_interim (status : Status.informational) (headers : Headers.t list) :
    interim_response =
  { status; headers }

let handle ~(on_data : body_reader) = on_data
