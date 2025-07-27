open H2kit

type ty = {
  writer : Buf_write.t;
  record_event : Event.t -> unit;
  hpack : Hpack.Encoder.t;
}

let create :
    writer:Buf_write.t ->
    record_event:(Event.t -> unit) ->
    hpack:Hpack.Encoder.t ->
    ty =
 fun ~writer ~record_event ~hpack -> { writer; record_event; hpack }

open Serializers.Make (Buf_write)

type t = ty

let ( ++ ) : (t -> unit) -> (t -> unit) -> t -> unit =
 fun f1 f2 w ->
  f1 w;
  f2 w

let settings ?(flags = Flags.default_flags) ?len ?(id = 0l) settings
    { writer; record_event; _ } =
  let frame_header =
    {
      Frame.flags;
      payload_length = Option.value ~default:(List.length settings * 6) len;
      stream_id = id;
      frame_type = Settings;
    }
  in
  let frame = { Frame.frame_header; frame_payload = Settings settings } in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  LowLevel.write_settings_frame_payload settings writer

let unknown_setting { writer; record_event; _ } =
  let frame_header =
    {
      Frame.flags = Flags.default_flags;
      payload_length = 12;
      stream_id = 0l;
      frame_type = Settings;
    }
  in
  let frame =
    {
      Frame.frame_header;
      frame_payload = Settings [ EnablePush 0; EnablePush 0 ];
    }
  in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  LowLevel.write_settings_frame_payload [ EnablePush 0 ] writer;
  Buf_write.BE.write_uint16 writer 7;
  Buf_write.BE.write_uint32 writer 10l

let ping ?(flags = Flags.default_flags) ?(len = 8) ?(id = 0l) payload
    { writer; record_event; _ } =
  let frame_header =
    { Frame.flags; payload_length = len; stream_id = id; frame_type = Ping }
  in
  let frame =
    { Frame.frame_header; frame_payload = Ping (Cstruct.of_string payload) }
  in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  Buf_write.schedule_cstruct writer (Cstruct.of_string payload)

let goaway ?(flags = Flags.default_flags) ?(len = 8) ?(id = 0l) code
    { writer; record_event; _ } =
  let frame_header =
    { Frame.flags; payload_length = len; stream_id = id; frame_type = GoAway }
  in

  let frame =
    { Frame.frame_header; frame_payload = GoAway (0l, code, Bigstringaf.empty) }
  in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  LowLevel.write_goaway_frame_payload 0l code writer

let window_update ?(flags = Flags.default_flags) ?(len = 4) ?(id = 0l) incr
    { writer; record_event; _ } =
  let frame_header =
    {
      Frame.flags;
      payload_length = len;
      stream_id = id;
      frame_type = WindowUpdate;
    }
  in

  let frame = { Frame.frame_header; frame_payload = WindowUpdate incr } in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  LowLevel.write_window_update_frame_payload incr writer

let unknown { writer; record_event; _ } =
  let payload = "12345678" in
  let frame_header =
    {
      Frame.flags = Flags.default_flags;
      stream_id = 0l;
      frame_type = Unknown 20;
      payload_length = 8;
    }
  in

  let frame =
    {
      Frame.frame_header;
      frame_payload = Unknown (20, Bigstringaf.of_string ~off:0 ~len:8 payload);
    }
  in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  Buf_write.schedule_cstruct writer (Cstruct.of_string payload)

let headers ?(flags = Flags.(default_flags |> set_end_header |> set_end_stream))
    ?len ?(id = 1l) ?pad_len headers { writer; hpack = encoder; record_event } =
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

  let frame_header =
    {
      Frame.flags;
      payload_length = Option.value ~default:length len;
      stream_id = id;
      frame_type = Headers;
    }
  in
  let payload_data = Faraday.serialize_to_bigstring tmp_faraday in

  let frame = { Frame.frame_header; frame_payload = Headers payload_data } in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  Option.iter (Buf_write.uint8 writer) pad_len;
  Buf_write.schedule_bigstring writer payload_data;
  Option.iter
    (fun pad_len ->
      let padding = Cstruct.create pad_len in
      Cstruct.memset padding 0;
      Buf_write.cstruct writer padding)
    pad_len

let rst_stream ?(flags = Flags.default_flags) ?(len = 4) ?(id = 1l) code
    { writer; record_event; _ } =
  let frame_header =
    {
      Frame.flags;
      payload_length = len;
      stream_id = id;
      frame_type = RSTStream;
    }
  in
  let frame = { Frame.frame_header; frame_payload = RSTStream code } in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  LowLevel.write_rst_stream_frame_payload code writer

let data ?(flags = Flags.default_flags) ?len ?(id = 1l) cs
    { writer; record_event; _ } =
  let frame_header =
    {
      Frame.flags;
      payload_length = Option.value ~default:(Cstruct.length cs) len;
      stream_id = id;
      frame_type = Data;
    }
  in

  let frame = { Frame.frame_header; frame_payload = Data cs } in

  record_event (Frame frame);

  LowLevel.write_frame_header frame_header writer;
  LowLevel.write_data_frame_payload [ cs ] writer
