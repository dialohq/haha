open Body

type 'context final_response = {
  status : Status.t;
  headers : Headers.t;
  body_writer : 'context writer option;
}

type interim_response = { status : Status.informational; headers : Headers.t }

type 'context t =
  [ `Interim of interim_response | `Final of 'context final_response ]

type 'context response_writer = unit -> 'context t

let create ?(headers = Headers.empty) ?body_writer (status : Status.t) :
    'context final_response =
  { status; headers; body_writer }

let create_interim ?(headers = Headers.empty) (status : Status.informational) :
    interim_response =
  { status; headers }
