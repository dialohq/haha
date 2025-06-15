open H2kit

let make_header_cs ~payload_length ~frame_type ~flags ~stream_id =
  let cs = Cstruct.create 9 in
  Cstruct.set_uint8 cs 0 ((payload_length lsr 16) land 0xFF);
  Cstruct.set_uint8 cs 1 ((payload_length lsr 8) land 0xFF);
  Cstruct.set_uint8 cs 2 (payload_length land 0xFF);
  Cstruct.set_uint8 cs 3 (Frame.FrameType.to_int frame_type);
  Cstruct.set_uint8 cs 4 (Flags.to_int flags);
  Cstruct.BE.set_uint32 cs 5 stream_id;
  cs
