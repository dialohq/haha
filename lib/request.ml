type t =
  | Request : {
      path : string;
      meth : Method.t;
      authority : string option;
      scheme : string;
      headers : Header.t list;
      body_writer : 'context Body.writer option;
      response_handler : 'context Response.handler;
      error_handler : 'context -> Error_code.t -> 'context;
      initial_context : 'context;
    }
      -> t

type request_writer = unit -> t option

let path (Request t) = t.path
let meth (Request t) = t.meth
let scheme (Request t) = t.scheme
let authority (Request t) = t.authority
let headers (Request t) = t.headers

let create ?authority ?(scheme = "http") ~context ~response_handler
    ~error_handler ~headers meth path =
  Request
    {
      path;
      meth;
      authority;
      scheme;
      headers;
      body_writer = None;
      response_handler;
      error_handler;
      initial_context = context;
    }

let create_with_streaming ?authority ?(scheme = "http") ~context ~body_writer
    ~response_handler ~error_handler ~headers meth path =
  Request
    {
      path;
      meth;
      authority;
      scheme;
      headers;
      body_writer = Some body_writer;
      response_handler;
      error_handler;
      initial_context = context;
    }
