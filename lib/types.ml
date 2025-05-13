type 'state step =
  | End
  | ConnectionError of Error.connection_error
  | NextState of 'state

type body_reader_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Header.t list ]

type 'context body_writer_fragment =
  [ `Data of Cstruct.t list
  | `End of Cstruct.t list option * Header.t list
  | `Yield ]
  * (unit -> unit)
  * 'context

type 'context body_reader = 'context -> body_reader_fragment -> 'context

type 'context body_writer =
  'context -> window_size:int32 -> 'context body_writer_fragment
