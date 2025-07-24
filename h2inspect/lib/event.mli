open H2kit

type t =
  | Frame of Frame.t
  | Malformed
  | ValidationFailed of Error.t
  | Magic
  | EOF
  | Timeout
[@@deriving show]

type 'a matcher = t -> ('a, string) result

val magic : unit matcher
val eof : unit matcher
val settings : Settings.setting list matcher
val settings_ack : Settings.setting list matcher

val frame_header :
  ?flags:Flags.t -> ?id:int32 -> Frame.FrameType.t -> Frame.frame_header matcher

val goaway : (int32 * Error_code.t * Bigstringaf.t) matcher
val goaway_code : Error_code.t -> Error_code.t matcher
val headers : unit matcher
val data : Cstruct.t matcher
val ping : unit matcher
val ping_p : string -> unit matcher
val stream_error : int32 -> Error_code.t -> unit matcher
val timeout : unit matcher
