open H2kit

type t =
  | Frame of Frame.t
  | Malformed
  | ValidationFailed of Error.t
  | Magic
  | EOF
  | Timeout
[@@deriving show]

type matcher = t -> (unit, string) result

val magic : matcher
val eof : matcher
val settings : matcher
val settings_ack : matcher
val frame_header : ?flags:Flags.t -> ?id:int32 -> Frame.FrameType.t -> matcher
val goaway : matcher
val goaway_code : Error_code.t -> matcher
val headers : matcher
val data : matcher
val ping : matcher
val ping_p : string -> matcher
val stream_error : int32 -> Error_code.t -> matcher
