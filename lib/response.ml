open Body

type 'context final_response = {
  status : Status.t;
  headers : Header.t list;
  body_writer : 'context writer option;
}

type interim_response = {
  status : Status.informational;
  headers : Header.t list;
}

type 'context t =
  [ `Interim of interim_response | `Final of 'context final_response ]

type 'context handler =
  'context -> 'context t -> 'context reader option * 'context

type 'context response_writer = unit -> 'context t

let status (t : _ t) =
  match t with `Interim r -> (r.status :> Status.t) | `Final r -> r.status

let headers (t : _ t) =
  match t with `Interim r -> r.headers | `Final r -> r.headers

let create (status : Status.t) (headers : Header.t list) :
    'context final_response =
  { status; headers; body_writer = None }

let create_interim (status : Status.informational) (headers : Header.t list) :
    interim_response =
  { status; headers }

let create_with_streaming ~(body_writer : 'context writer) (status : Status.t)
    (headers : Header.t list) : 'context final_response =
  { status; headers; body_writer = Some body_writer }
