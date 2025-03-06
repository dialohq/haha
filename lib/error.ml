type t =
  | ConnectionError of Error_code.t * string
  | StreamError of Stream_identifier.t * Error_code.t

let message = function ConnectionError (_, msg) -> msg | StreamError _ -> ""
let connection_error error_code msg = Error (ConnectionError (error_code, msg))
