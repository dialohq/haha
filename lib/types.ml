type 'input state =
  | InProgress of ('input list -> 'input iteration)
  | End
  | Error of Error.connection_error

and 'input iteration = { state : 'input state; active_streams : int }
