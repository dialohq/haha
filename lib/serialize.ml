open Faraday

type frame_info = { flags : Flags.t; stream_id : Stream_identifier.t }

let write_uint24 t n =
  let write_octet t o = write_uint8 t (o land 0xff) in
  write_octet t (n lsr 16);
  write_octet t (n lsr 8);
  write_octet t n

let write_frame_header t frame_header =
  let { Frame.payload_length; flags; stream_id; frame_type } = frame_header in
  write_uint24 t payload_length;
  write_uint8 t (Frame.FrameType.serialize frame_type);
  write_uint8 t flags;
  BE.write_uint32 t stream_id

let write_settings_frame t info settings =
  let header =
    {
      Frame.flags = info.flags;
      stream_id = info.stream_id;
      payload_length = List.length settings * 6;
      frame_type = Settings;
    }
  in
  write_frame_header t header;
  Settings.write_settings_payload t settings

let write_ping_frame t info ?(off = 0) payload =
  let payload_length = 8 in
  let header =
    {
      Frame.flags = info.flags;
      stream_id = info.stream_id;
      payload_length;
      frame_type = Ping;
    }
  in
  write_frame_header t header;
  schedule_bigstring ~off ~len:payload_length t payload

let write_window_update_frame t stream_id window_size =
  if not (is_closed t) then (
    let header =
      {
        Frame.flags = Flags.default_flags;
        stream_id;
        (* From RFC7540§6.9:
         *   The payload of a WINDOW_UPDATE frame is one reserved bit plus an
         *   unsigned 31-bit integer indicating the number of octets that the
         *   sender can transmit in addition to the existing flow-control
         *   window. *)
        payload_length = 4;
        frame_type = WindowUpdate;
      }
    in
    write_frame_header t header;
    BE.write_uint32 t window_size)
