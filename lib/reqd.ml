open H2kit

type t = {
  meth : Method.t;
  path : string;
  scheme : string;
  authority : string option;
  headers : Headers.t;
}

type handler_result =
  | ReqdHandle : {
      body_reader : 'context Body.reader;
      response_writer : 'context Response.response_writer;
      error_handler : 'context -> Error.t -> 'context;
      context : 'context;
      on_close : 'context -> unit;
    }
      -> handler_result

type handler = t -> handler_result

let path t = t.path
let meth t = t.meth
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers

let handle ?(on_close = ignore) ~context ~response_writer ~body_reader
    ~error_handler () =
  ReqdHandle { body_reader; response_writer; error_handler; on_close; context }

let pp_hum fmt { meth; path; _ } =
  Format.fprintf fmt "%s %s" (Method.to_string meth) path
