val connection_preface : string
(** Magic string for client's connection preface *)

module FrameType : sig
  (** Type representing the type of frame *)
  type t =
    | Data
    | Headers
    | Priority
    | RSTStream
    | Settings
    | PushPromise
    | Ping
    | GoAway
    | WindowUpdate
    | Continuation
    | Unknown of int

  val to_int : t -> int
  val of_int : int -> t
  val pp_hum : Format.formatter -> t -> unit
end

type frame_header = {
  payload_length : int;
  flags : Flags.t;
  stream_id : Stream_identifier.t;
  frame_type : FrameType.t;
}
(** Type representing the frame's header *)

(** Type representing the frame's payload according to the type of frame *)
type frame_payload =
  | Data of Bigstringaf.t
  | Headers of Bigstringaf.t
  | Priority
  | RSTStream of Error_code.t
  | Settings of Settings.setting list
  | PushPromise of Stream_identifier.t * Bigstringaf.t
  | Ping of Bigstringaf.t
  | GoAway of (Stream_identifier.t * Error_code.t * Bigstringaf.t)
  | WindowUpdate of Window_size.t
  | Continuation of Bigstringaf.t
  | Unknown of int * Bigstringaf.t

type t = { frame_header : frame_header; frame_payload : frame_payload }
(** Type representing a HTTP/2 frame *)

val validate_header : frame_header -> (unit, Error.t) result
(** [validate_header header] is the first validation of the parsed frame's
    header information.

    This should be used after parsing the frame's header and before parsing its
    payload. It performs basic validation without context of the connection
    state (e.g. checking if the connection-level-only frames have their stream
    id equal to 0).

    @return A appropriate {!Error.t} if the validation fails or unit on success.
*)

val pp_hum : Format.formatter -> t -> unit
(** Human-readable formatter for the [t] type. Useful for debbugging. *)
