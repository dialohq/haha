type 'input state =
  | InProgress of ('input list -> 'input iteration)
  | End
  | Error of H2kit.Error.connection_error

and 'input iteration = { state : 'input state; active_streams : int }
