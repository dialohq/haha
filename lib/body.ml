type reader_fragment =
  [ `Data of Cstruct.t | `End of Cstruct.t option * Header.t list ]

type 'context reader_result = {
  action : [ `Continue | `Reset ];
  context : 'context;
}

type 'context writer_fragment =
  [ `Data of Cstruct.t list | `End of Cstruct.t list option * Header.t list ]

type 'context writer_result = {
  payload : 'context writer_fragment;
  on_flush : unit -> unit;
  context : 'context;
}

type 'context body_reader =
  'context -> reader_fragment -> 'context reader_result

type 'context body_writer =
  'context -> window_size:int32 -> 'context writer_result
