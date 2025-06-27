type connection_error =
  | ProtocolViolation of
      ((Error_code.t * string)
      [@equal fun (x, _) (y, _) -> Error_code.equal x y])
  | Exn of
      (exn
      [@printer fun fmt t -> fprintf fmt "%s" (Printexc.to_string t)]
      [@equal fun _ _ -> true])
  | PeerError of (Error_code.t * string)
[@@deriving show { with_path = false }, eq]

type stream_error = Stream_identifier.t * Error_code.t [@@deriving show, eq]

type t = ConnectionError of connection_error | StreamError of stream_error
[@@deriving show { with_path = false }, eq]

let conn_prot_err : Error_code.t -> ('a, unit, string, t) format4 -> 'a =
 fun code fmt ->
  Printf.ksprintf
    (fun msg -> ConnectionError (ProtocolViolation (code, msg)))
    fmt

let stream_prot_err : Stream_identifier.t -> Error_code.t -> t =
 fun stream_id code -> StreamError (stream_id, code)
