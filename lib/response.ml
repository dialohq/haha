open Body

type final_response = {
  status : Status.t;
  headers : Headers.t;
  body_writer : writer option;
}

type interim_response = { status : Status.informational; headers : Headers.t }
type t = [ `Interim of interim_response | `Final of final_response ]
type response_writer = unit -> t

let create ?(headers = Headers.empty) ?body_writer (status : Status.t) :
    final_response =
  { status; headers; body_writer }

let create_interim ?(headers = Headers.empty) (status : Status.informational) :
    interim_response =
  { status; headers }
