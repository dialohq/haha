open H2kit

type t =
  | Frame of Frame.t
  | Malformed
  | ValidationFailed of Error.t
  | Magic
  | EOF
  | Timeout
