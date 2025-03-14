module Error = Error
module Error_code = Error_code
module Method = Method
module Status = Status

module Settings : sig
  type t = {
    header_table_size : int;
    enable_push : bool;
    max_concurrent_streams : int32;
    initial_window_size : int32;
    max_frame_size : int;
    max_header_list_size : int option;
  }

  val default : t
  val pp_hum : Format.formatter -> t -> unit
end

module Headers = Headers
module Response = Response
module Request = Request
module Server = Server

(* module Headers : sig *)
(*   type t = { name : string; value : string } *)
(**)
(*   val of_list : (string * string) list -> t list *)
(* end *)
(**)
(* module Response : sig *)
(*   type t *)
(*   type body_fragment = [ `Data of Cstruct.t | `EOF ] *)
(*   type body_writer = unit -> body_fragment *)
(**)
(*   val create_final : Status.final -> Headers.t list -> t *)
(**)
(*   val create_final_with_streaming : *)
(*     body_writer:body_writer -> Status.final -> Headers.t list -> t *)
(**)
(*   val create_interim : Status.informational -> Headers.t list -> t *)
(*   val create_trailers : Headers.t list -> t *)
(* end *)
(**)
(* module Request : sig *)
(*   type t *)
(**)
(*   val path : t -> string *)
(*   val meth : t -> Method.t *)
(*   val headers : t -> Headers.t list *)
(**)
(*   val handle : *)
(*     response_writer:(unit -> Response.t) -> *)
(*     on_data:(Cstruct.t -> unit) -> *)
(*     (Cstruct.t -> unit) * (unit -> Response.t) *)
(* end *)
(**)
(* module Streams = Streams *)
(**)
(* module Server : sig *)
(*   type request_handler = *)
(*     Request.t -> Streams.Stream.(stream_reader * response_writer) *)
(**)
(*   val connection_handler : request_handler -> _ Eio.Net.connection_handler *)
(* end *)
