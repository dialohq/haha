type state =
  | InProgress of (unit -> iteration)
  | End
  | Error of Error.connection_error

and iteration = { state : state; active_streams : int }
