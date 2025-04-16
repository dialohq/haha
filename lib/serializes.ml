open Faraday

type frame_info = {
  flags : Flags.t;
  stream_id : Stream_identifier.t;
  padding_length : int;
}

let create_frame_info ?(flags = Flags.default_flags) ?(padding_length = 0)
    stream_id =
  { flags; stream_id; padding_length }

let padding_buffer = Bigstringaf.create 5000 |> ref

let get_padding n =
  if n <= Bigstringaf.length !padding_buffer then
    Bigstringaf.sub ~off:0 ~len:n !padding_buffer
  else (
    padding_buffer := Bigstringaf.create (2 * n);
    Bigstringaf.sub ~off:0 ~len:n !padding_buffer)

let write_uint24 t n =
  let write_octet t o = write_uint8 t (o land 0xff) in
  write_octet t (n lsr 16);
  write_octet t (n lsr 8);
  write_octet t n

let write_connection_preface t = write_string t Frame.connection_preface

let write_frame_header t frame_header =
  let { Frame.payload_length; flags; stream_id; frame_type } = frame_header in
  write_uint24 t payload_length;
  write_uint8 t (Frame.FrameType.serialize frame_type);
  write_uint8 t flags;
  BE.write_uint32 t stream_id

let write_frame_with_padding t info frame_type length writer =
  let header, writer =
    if info.padding_length = 0 then
      let header =
        {
          Frame.payload_length = length;
          flags = info.flags;
          stream_id = info.stream_id;
          frame_type;
        }
      in
      (header, writer)
    else
      let pad_length = info.padding_length in
      let writer' t =
        write_uint8 t pad_length;
        writer t;
        schedule_bigstring ~off:0 ~len:pad_length t
          (get_padding info.padding_length)
      in
      let header =
        {
          Frame.payload_length = length + pad_length + 1;
          flags = Flags.set_padded info.flags;
          stream_id = info.stream_id;
          frame_type;
        }
      in
      (header, writer')
  in
  write_frame_header t header;
  writer t

let write_data_frame t total_len cs_list info =
  let writer t =
    List.iter
      (fun (cs : Cstruct.t) ->
        schedule_bigstring t cs.buffer ~off:cs.off ~len:cs.len)
      cs_list
  in

  write_frame_with_padding t info Data total_len writer

let write_rst_stream_frame t stream_id e =
  let header =
    {
      Frame.flags = Flags.default_flags;
      stream_id;
      payload_length = 4;
      frame_type = RSTStream;
    }
  in
  write_frame_header t header;
  BE.write_uint32 t (Error_code.serialize e)

let write_headers t hpack_encoder frame_info headers =
  let writer t =
    List.iter
      (fun header ->
        Hpackv.Encoder.encode_header hpack_encoder t
          {
            Hpackv.name = header.Headers.name;
            value = header.value;
            sensitive = false;
          })
      headers
  in

  let length =
    List.fold_left
      (fun acc header ->
        acc
        + Hpackv.Encoder.calculate_length hpack_encoder
            {
              Hpackv.name = header.Headers.name;
              value = header.value;
              sensitive = false;
            })
      0 headers
  in
  write_frame_with_padding t frame_info Headers length writer

let write_response_headers t hpack_encoder frame_info status headers =
  let headers =
    match status with
    | Some status ->
        { Headers.name = ":status"; value = Status.to_string status } :: headers
    | None -> headers
  in

  write_headers t hpack_encoder frame_info headers

let write_request_headers ?authority t hpack_encoder frame_info meth path scheme
    headers =
  let headers =
    { Headers.name = ":method"; value = Method.to_string meth }
    :: { name = ":path"; value = path }
    :: { name = ":scheme"; value = scheme }
    ::
    (match authority with
    | None -> headers
    | Some authority -> { name = ":authority"; value = authority } :: headers)
  in

  write_headers t hpack_encoder frame_info headers

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

let write_go_away_frame ?(debug_data = Bigstringaf.empty) t last_stream_id
    error_code =
  let debug_data_len = Bigstringaf.length debug_data in
  let header =
    {
      Frame.flags = Flags.default_flags;
      stream_id = Stream_identifier.connection;
      payload_length = 8 + debug_data_len;
      frame_type = GoAway;
    }
  in
  write_frame_header t header;
  BE.write_uint32 t last_stream_id;
  BE.write_uint32 t (Error_code.serialize error_code);
  schedule_bigstring t ~off:0 ~len:debug_data_len debug_data

let write_window_update_frame t stream_id window_size =
  let header =
    {
      Frame.flags = Flags.default_flags;
      stream_id;
      payload_length = 4;
      frame_type = WindowUpdate;
    }
  in
  write_frame_header t header;
  BE.write_uint32 t window_size
