type token = Magic_string | Frame of Frame.t
type body_reader = Cstruct.t -> unit

type body_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Headers.t list | `Yield ]

type body_writer = window_size:int32 -> body_fragment
