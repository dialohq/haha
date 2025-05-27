type reader_payload =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Header.t list ]

type 'context reader_result = {
  action : [ `Continue | `Reset ];
  context : 'context;
}

type 'context writer_payload =
  [ `Data of Cstruct.t list | `End of Cstruct.t list option * Header.t list ]

type 'context writer_result = {
  payload : 'context writer_payload;
  on_flush : unit -> unit;
  context : 'context;
}

type 'context reader = 'context -> reader_payload -> 'context reader_result
type 'context writer = 'context -> window_size:int32 -> 'context writer_result
