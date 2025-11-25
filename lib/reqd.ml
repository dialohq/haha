type t = {
  meth : Method.t;
  path : string;
  scheme : string;
  authority : string option;
  headers : Headers.t;
}

type handler_result = {
  body_reader : Body.reader;
  response_writer : Response.response_writer;
  error_handler : Error_code.t -> unit;
  on_close : unit -> unit;
}

type handler = t -> handler_result

let path t = t.path
let meth t = t.meth
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers

let handle ?(on_close = ignore) ~response_writer ~body_reader ~error_handler ()
    =
  { body_reader; response_writer; error_handler; on_close }

let pp_hum fmt { meth; path; _ } =
  Format.fprintf fmt "%s %s" (Method.to_string meth) path
