open Types

type response_handler = Response.t -> body_reader

type t = {
  path : string;
  meth : Method.t;
  authority : string option;
  scheme : string;
  headers : Headers.t list;
  body_writer : body_writer option;
  response_handler : response_handler option;
  error_handler : Error.stream_error -> unit;
}

type request_writer = unit -> t option

let path t = t.path
let meth t = t.meth
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers

let create ?authority ?(scheme = "http") ~(response_handler : response_handler)
    ~error_handler ~headers meth path =
  {
    path;
    meth;
    authority;
    scheme;
    headers;
    body_writer = None;
    response_handler = Some response_handler;
    error_handler;
  }

let create_with_streaming ?authority ?(scheme = "http") ~body_writer
    ~(response_handler : response_handler) ~error_handler ~headers meth path =
  {
    path;
    meth;
    authority;
    scheme;
    headers;
    body_writer = Some body_writer;
    response_handler = Some response_handler;
    error_handler;
  }

let handle ~(response_writer : unit -> Response.t) ~error_handler
    ~(on_data : body_reader) =
  (on_data, response_writer, error_handler)
