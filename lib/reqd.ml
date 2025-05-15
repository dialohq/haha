open Types

type t = {
  meth : Method.t;
  path : string;
  scheme : string;
  authority : string option;
  headers : Header.t list;
}

type 'context handler =
  'context body_reader
  * 'context Response.response_writer
  * ('context -> Error_code.t -> 'context)
  * 'context

let path t = t.path
let meth t = t.meth
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers

let handle ~context ~(response_writer : unit -> 'context Response.t)
    ~error_handler ~(on_data : _ body_reader) =
  (on_data, response_writer, error_handler, context)
