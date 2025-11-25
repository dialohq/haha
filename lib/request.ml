type t = {
  path : string;
  meth : Method.t;
  authority : string option;
  scheme : string;
  headers : Headers.t;
  body_writer : Body.writer option;
  response_handler : Respd.handler;
  error_handler : Error_code.t -> unit;
  on_close : unit -> unit;
}

let create ?authority ?(scheme = "http") ?(on_close = ignore)
    ?(headers = Headers.empty) ~response_handler ~error_handler meth path =
  {
    path;
    meth;
    authority;
    scheme;
    headers;
    body_writer = None;
    response_handler;
    error_handler;
    on_close;
  }

let create_with_streaming ?authority ?(scheme = "http") ?(on_close = ignore)
    ?(headers = Headers.empty) ~body_writer ~response_handler ~error_handler
    meth path =
  {
    path;
    meth;
    authority;
    scheme;
    headers;
    body_writer = Some body_writer;
    response_handler;
    error_handler;
    on_close;
  }
