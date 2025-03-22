type body_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Headers.t list | `Yield ]

type body_writer = window_size:int32 -> body_fragment

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

let create (status : Status.t) (headers : Headers.t list) : final_response =
  { status; headers; body_writer = None }

let create_with_streaming ~(body_writer : body_writer) (status : Status.t)
    (headers : Headers.t list) : final_response =
  { status; headers; body_writer = Some body_writer }

let create_interim (status : Status.informational) (headers : Headers.t list) :
    interim_response =
  { status; headers }

(*

************

1. Final response - non-100 status, end_stream

************

************

1. Many interim responses - 1xx status

2. Final response - non-1xx status, end_stream

************

************

1. Many interim responses - 1xx status

2. Response - non-1xx status

3. Trailers - no status, end_stream

************

*)
