(** Types for HTTP/2 errors *)

(** Type representing connection-level errors *)
type connection_error =
  | ProtocolViolation of (Error_code.t * string)
      (** [ProtocolViolation] error occurs after missbehavior of the peer
          described as connection error by the RFC. This should be then reported
          to the peer with the GOAWAY frame. *)
  | Exn of exn
      (** [Exn] is a local exception. This should be then reported to the peer
          with the GOAWAY frame. *)
  | PeerError of (Error_code.t * string)
      (** [PeerError] is an error reported by the peer to us with the GOAWAY
          frame *)

type stream_error = Stream_identifier.t * Error_code.t
(** Type representing stream-level errors.

    It's most likely inrelevant for the user whether the error was caused by the
    peer's protocol violation or was reported by the peer, so there is no
    destinction here. *)

(** Type representing all kinds of errors *)
type t = ConnectionError of connection_error | StreamError of stream_error
[@@deriving show { with_path = false }, eq]

val conn_prot_err : Error_code.t -> ('a, unit, string, t) format4 -> 'a
(** [conn_prot_err code format arg1 ... argN] is like
    [ConnectionError (ProtocolViolation (code, msg))] where [msg] is
    {!Stdlib.Printf.sprintf format arg1 ... argN} *)

val stream_prot_err : Stream_identifier.t -> Error_code.t -> t
(** [stream_prot_err id code] is [StreamError (id, code)] *)
