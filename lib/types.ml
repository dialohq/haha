type 'context step =
  | Next of ((unit -> 'context step) * (int32 * 'context) list)
  | End of (int32 * 'context) list
  | Error of (Error.connection_error * (int32 * 'context) list)

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
