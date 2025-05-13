open Types

type 'context final_response = {
  status : Status.t;
  headers : Headers.t list;
  body_writer : 'context body_writer option;
}

type 'context interim_response = {
  status : Status.informational;
  headers : Headers.t list; (* initial_context : 'context; *)
}

type 'context t =
  [ `Interim of 'context interim_response | `Final of 'context final_response ]

type 'context response_writer = unit -> 'context t

let status (t : _ t) =
  match t with `Interim r -> (r.status :> Status.t) | `Final r -> r.status

let headers (t : _ t) =
  match t with `Interim r -> r.headers | `Final r -> r.headers

let create (status : Status.t) (headers : Headers.t list) :
    'context final_response =
  { status; headers; body_writer = None }

let create_with_streaming ~(body_writer : 'context body_writer)
    (status : Status.t) (headers : Headers.t list) : 'context final_response =
  { status; headers; body_writer = Some body_writer }

let create_interim (status : Status.informational) (headers : Headers.t list) :
    'context interim_response =
  { status; headers }

let handle ~(on_data : _ body_reader) = on_data
