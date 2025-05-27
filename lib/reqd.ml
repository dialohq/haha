type t = {
  meth : Method.t;
  path : string;
  scheme : string;
  authority : string option;
  headers : Header.t list;
}

type 'context handler_result = {
  on_data : 'context Body.reader;
  response_writer : 'context Response.response_writer;
  error_handler : 'context -> Error_code.t -> 'context;
  initial_context : 'context;
}

type 'context handler = t -> 'context handler_result

let path t = t.path
let meth t = t.meth
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers
