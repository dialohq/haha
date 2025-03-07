type connection_error = Error_code.t * string
type stream_error = Stream_identifier.t * Error_code.t
type t = ConnectionError of connection_error | StreamError of stream_error

let message = function ConnectionError (_, msg) -> msg | StreamError _ -> ""
let connection_error error_code msg = Error (ConnectionError (error_code, msg))
