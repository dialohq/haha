type reader_payload = [ `Data of Cstruct.t | `End of Headers.t ]

type writer_payload =
  [ `Data of Cstruct.t list | `End of Cstruct.t list option * Headers.t ]

type reader = reader_payload -> unit
type writer = unit -> writer_payload

let ignore_reader : reader = fun _ -> ()
