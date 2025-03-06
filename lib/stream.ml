type source = Remote | Local
type state = Idle | Reserved of source | Open | Half_closed of source | Closed
type t = { id : Stream_identifier.t; state : state }
