open Eio

module Parsers = Parsers.Make (struct
  include Buf_read
  include Buf_read.Syntax

  type 'a t = 'a Buf_read.parser

  let unsafe_take_bigarray n =
   fun t ->
    ensure t n;
    let cs = peek t in
    assert (Cstruct.length cs >= n);
    consume t n;
    (* WARN: not a good idea probably, those bytes will be different on the next read from the socket *)
    Cstruct.(sub cs 0 n |> to_bigarray)
end)

type t = Buf_read.t

let ( >>= ) :
    (t -> ('a, Error.t) result) ->
    (t -> ('b, Error.t) result) ->
    t ->
    ('b, Error.t) result =
 fun r1 r2 t -> match r1 t with Error _ as err -> err | Ok _ -> r2 t

let create : [> Flow.source_ty ] Resource.t -> int -> t =
 fun flow size -> Buf_read.of_flow ~initial_size:size ~max_size:size flow

let update_size : int -> t -> t =
 fun _size _t ->
  (* TODO: copy all bytes from previous and create a new reader *)
  failwith "Reader.update_size not implemented"

let read_preface : t -> (unit, Error.t) result =
 fun t ->
  match Parsers.connection_preface t with
  | exception Failure msg ->
      Error
        (ConnectionError
           (Exn (Failure (Format.asprintf "parsing error: %s" msg))))
  | exception Buf_read.Buffer_limit_exceeded ->
      Error
        (Error.conn_prot_err ProtocolError
           "invalid connection preface, frame buffer exceeded")
  | exception exn -> Error (ConnectionError (Exn exn))
  | () -> Ok ()

let read_frame : t -> (Frame.t, Error.t) result =
 fun t ->
  match Parsers.parse_frame t with
  | exception Failure msg ->
      Error
        (ConnectionError
           (Exn (Failure (Format.asprintf "parsing error: %s" msg))))
  | exception Buf_read.Buffer_limit_exceeded ->
      Error (Error.conn_prot_err ProtocolError "frame buffer exceeded")
  | exception exn -> Error (ConnectionError (Exn exn))
  | res -> res
