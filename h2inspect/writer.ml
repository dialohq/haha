open H2kit

type ty = { writer : Buf_write.t; hpack : Hpack.Encoder.t }

let create : writer:Buf_write.t -> hpack:Hpack.Encoder.t -> ty =
 fun ~writer ~hpack -> { writer; hpack }

open Serializers.Make (Buf_write)

type t = ty

let settings ?(flags = Flags.default_flags) ?len ?(id = 0l) settings
    { writer; _ } =
  LowLevel.write_frame_header
    {
      flags;
      payload_length = Option.value ~default:(List.length settings * 6) len;
      stream_id = id;
      frame_type = Settings;
    }
    writer;
  LowLevel.write_settings_frame_payload settings writer

let unknown_setting { writer; _ } =
  LowLevel.write_frame_header
    {
      flags = Flags.default_flags;
      payload_length = 12;
      stream_id = 0l;
      frame_type = Settings;
    }
    writer;
  LowLevel.write_settings_frame_payload [ EnablePush 0 ] writer;
  Buf_write.BE.write_uint16 writer 7;
  Buf_write.BE.write_uint32 writer 10l

let ping ?(flags = Flags.default_flags) ?(len = 8) ?(id = 0l) payload
    { writer = w; _ } =
  LowLevel.write_frame_header
    { flags; payload_length = len; stream_id = id; frame_type = Ping }
    w;
  Buf_write.schedule_cstruct w (Cstruct.of_string payload)

let goaway ?(flags = Flags.default_flags) ?(len = 0) ?(id = 0l) code
    { writer; _ } =
  LowLevel.write_frame_header
    { flags; payload_length = len; stream_id = id; frame_type = GoAway }
    writer;
  LowLevel.write_goaway_frame_payload 0l code writer

let window_update ?(flags = Flags.default_flags) ?(len = 4) ?(id = 0l) incr
    { writer; _ } =
  LowLevel.write_frame_header
    { flags; payload_length = len; stream_id = id; frame_type = WindowUpdate }
    writer;
  LowLevel.write_window_update_frame_payload incr writer

let unknown { writer = w; _ } =
  LowLevel.write_frame_header
    {
      flags = Flags.default_flags;
      stream_id = 0l;
      frame_type = Unknown 20;
      payload_length = 8;
    }
    w;
  Buf_write.schedule_cstruct w (Cstruct.of_string "12345678")

let headers ?(flags = Flags.(default_flags |> set_end_header |> set_end_stream))
    ?len ?(id = 1l) ?pad_len headers { writer = w; hpack = encoder } =
  let tmp_faraday = Faraday.create 1_000 in

  (match headers with
  | `Block { Cstruct.off; len; buffer } ->
      Faraday.write_bigstring tmp_faraday ~off ~len buffer
  | `List headers ->
      let headers = Headers.of_list headers in
      Headers.iter
        (fun (name, value) ->
          Hpack.Encoder.encode_header encoder tmp_faraday
            { Hpack.name; value; sensitive = false })
        headers);

  let length = Faraday.pending_bytes tmp_faraday in

  LowLevel.write_frame_header
    {
      flags;
      payload_length = Option.value ~default:length len;
      stream_id = id;
      frame_type = Headers;
    }
    w;
  Option.iter (Buf_write.uint8 w) pad_len;
  Buf_write.schedule_bigstring w (Faraday.serialize_to_bigstring tmp_faraday);
  Option.iter
    (fun pad_len ->
      let padding = Cstruct.create pad_len in
      Cstruct.memset padding 0;
      Buf_write.cstruct w padding)
    pad_len

let rst_stream ?(flags = Flags.default_flags) ?(len = 4) ?(id = 1l) code
    { writer = w; _ } =
  LowLevel.write_frame_header
    { flags; payload_length = len; stream_id = id; frame_type = RSTStream }
    w;
  LowLevel.write_rst_stream_frame_payload code w
