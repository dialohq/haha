type connection_error =
  | ProtocolViolation of (Error_code.t * string)
  | PeerError of (Error_code.t * string)
  | Exn of exn

type stream_error = Stream_identifier.t * Error_code.t
type t = ConnectionError of connection_error | StreamError of stream_error

let conn_prot_err : Error_code.t -> string -> t =
 fun code msg -> ConnectionError (ProtocolViolation (code, msg))

let stream_prot_err : Stream_identifier.t -> Error_code.t -> t =
 fun stream_id code -> StreamError (stream_id, code)
