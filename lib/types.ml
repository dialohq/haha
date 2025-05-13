type token = Magic_string | Frame of Frame.t

type body_reader_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Headers.t list ]

type 'context body_writer_fragment =
  [ `Data of Cstruct.t list
  | `End of Cstruct.t list option * Headers.t list
  | `Yield ]
  * (unit -> unit)
  * 'context

type 'context body_reader = 'context -> body_reader_fragment -> 'context

type 'context body_writer =
  'context -> window_size:int32 -> 'context body_writer_fragment
