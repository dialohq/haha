type t = { path : string; meth : Method.t; headers : Headers.t list }

let path t = t.path
let meth t = t.meth
let headers t = t.headers

let handle ~(response_writer : unit -> Response.t)
    (* ~(body_writer : Response.body_writer) *)
    ~(on_data : Cstruct.t -> unit) =
  (on_data, response_writer)
