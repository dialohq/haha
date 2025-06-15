open H2kit

type reader_payload = [ `Data of Cstruct.t | `End of Headers.t ]

type 'context writer_payload =
  [ `Data of Cstruct.t list | `End of Cstruct.t list option * Headers.t ]

type 'context writer_result = {
  payload : 'context writer_payload;
  on_flush : unit -> unit;
  context : 'context;
}

type 'context reader = 'context -> reader_payload -> 'context
type 'context writer = 'context -> 'context writer_result

let ignore_reader : _ reader = fun context _ -> context
