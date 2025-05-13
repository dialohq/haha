open Types

type 'context response_handler = 'context Response.t -> 'context body_reader

type 'context t = {
  path : string;
  meth : Method.t;
  authority : string option;
  scheme : string;
  headers : Headers.t list;
  body_writer : 'context body_writer option;
  response_handler : 'context response_handler option;
  error_handler : Error_code.t -> unit;
  initial_context : 'context;
}

type 'context request_writer = unit -> 'context t option

let path t = t.path
let meth t = t.meth
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers

let create ?authority ?(scheme = "http") ~context
    ~(response_handler : 'context response_handler) ~error_handler ~headers meth
    path =
  {
    path;
    meth;
    authority;
    scheme;
    headers;
    body_writer = None;
    response_handler = Some response_handler;
    error_handler;
    initial_context = context;
  }

let create_with_streaming ?authority ?(scheme = "http") ~context ~body_writer
    ~(response_handler : 'context response_handler) ~error_handler ~headers meth
    path =
  {
    path;
    meth;
    authority;
    scheme;
    headers;
    body_writer = Some body_writer;
    response_handler = Some response_handler;
    error_handler;
    initial_context = context;
  }

let handle ~context ~(response_writer : unit -> 'context Response.t)
    ~error_handler ~(on_data : _ body_reader) =
  (on_data, response_writer, error_handler, context)
