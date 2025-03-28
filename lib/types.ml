type token = Magic_string | Frame of Frame.t

type body_reader_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Headers.t list ]

type body_writer_fragment =
  [ `Data of Cstruct.t list
  | `End of Cstruct.t list option * Headers.t list
  | `Yield ]

type body_reader = body_reader_fragment -> unit
type body_writer = window_size:int32 -> body_writer_fragment
