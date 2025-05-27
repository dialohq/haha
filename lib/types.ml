type 'context state =
  | InProgress of (unit -> 'context iteration)
  | End
  | Error of Error.connection_error

and 'context iteration = {
  state : 'context state;
  closed_ctxs : (int32 * 'context) list;
}
