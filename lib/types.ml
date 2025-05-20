type 'context state =
  | InProgress of (unit -> 'context iteration)
  | End
  | Error of Error.connection_error

and 'context iteration = {
  state : 'context state;
  closed_ctxs : (int32 * 'context) list;
}

type body_reader_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Header.t list ]

type 'context body_writer_fragment =
  [ `Data of Cstruct.t list
  | `End of Cstruct.t list option * Header.t list
  | `Yield ]
  * (unit -> unit)
  * 'context

type 'context body_reader_result = {
  action : [ `Continue | `Reset ];
  context : 'context;
}

type 'context body_reader =
  'context -> body_reader_fragment -> 'context body_reader_result

type 'context body_writer =
  'context -> window_size:int32 -> 'context body_writer_fragment
