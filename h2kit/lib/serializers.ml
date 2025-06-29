module type BufWriterType = sig
  type t

  val write_uint8 : t -> int -> unit
  val write_string : t -> ?off:int -> ?len:int -> string -> unit
  val schedule_bigstring : t -> ?off:int -> ?len:int -> Bigstringaf.t -> unit

  module BE : sig
    val write_uint16 : t -> int -> unit
    val write_uint32 : t -> int32 -> unit
  end
end

module type S = sig
  type t
  type frame_info

  val create_frame_info :
    ?flags:Flags.t -> ?padding_length:int -> int32 -> frame_info

  val write_connection_preface : t -> unit
  val write_data_frame : t -> Cstruct.t list -> frame_info -> unit

  val write_headers_frame :
    t -> Hpack.Encoder.t -> Headers.t -> frame_info -> unit

  val write_rst_stream_frame : t -> Stream_identifier.t -> Error_code.t -> unit
  val write_settings_frame : t -> Settings.setting list -> frame_info -> unit
  val write_ping_frame : t -> Cstruct.t -> frame_info -> unit

  val write_goaway_frame :
    ?debug_data:Cstruct.t -> t -> Stream_identifier.t -> Error_code.t -> unit

  val write_window_update_frame : t -> Stream_identifier.t -> int32 -> unit
  val write_frame_header : t -> Frame.frame_header -> unit
end

module Make (BufWriter : BufWriterType) = struct
  open BufWriter

  type t = BufWriter.t

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
    write_uint8 t (Frame.FrameType.to_int frame_type);
    write_uint8 t (Flags.to_int flags);
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

  let write_data_frame t cs_list info =
    let writer t =
      List.iter
        (fun (cs : Cstruct.t) ->
          schedule_bigstring t cs.buffer ~off:cs.off ~len:cs.len)
        cs_list
    in

    write_frame_with_padding t info Data (Cstruct.lenv cs_list) writer

  let write_rst_stream_frame t stream_id error_code =
    let header =
      {
        Frame.flags = Flags.default_flags;
        stream_id;
        payload_length = 4;
        frame_type = RSTStream;
      }
    in
    write_frame_header t header;
    BE.write_uint32 t (Error_code.serialize error_code)

  let write_headers_frame t hpack_encoder headers frame_info =
    let tmp_faraday = Faraday.create 1_000 in
    let writer t =
      Headers.iter
        (fun (name, value) ->
          Hpack.Encoder.encode_header hpack_encoder t
            { Hpack.name; value; sensitive = false })
        headers
    in

    writer tmp_faraday;
    let length = Faraday.pending_bytes tmp_faraday in

    let writer t =
      schedule_bigstring t (Faraday.serialize_to_bigstring tmp_faraday)
    in
    write_frame_with_padding t frame_info Headers length writer

  let write_settings_frame t settings info =
    let header =
      {
        Frame.flags = info.flags;
        stream_id = info.stream_id;
        payload_length = List.length settings * 6;
        frame_type = Settings;
      }
    in
    write_frame_header t header;
    List.iter
      (fun setting ->
        BE.write_uint16 t (Settings.serialize_key setting);
        match setting with
        | Settings.MaxConcurrentStreams value | InitialWindowSize value ->
            BE.write_uint32 t value
        | HeaderTableSize value
        | EnablePush value
        | MaxFrameSize value
        | MaxHeaderListSize value ->
            BE.write_uint32 t (Int32.of_int value))
      settings

  let write_ping_frame t cs info =
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
    schedule_bigstring ~off:cs.Cstruct.off ~len:payload_length t cs.buffer

  let write_goaway_frame ?(debug_data = Cstruct.empty) t last_stream_id
      error_code =
    let header =
      {
        Frame.flags = Flags.default_flags;
        stream_id = Stream_identifier.connection;
        payload_length = 8 + debug_data.len;
        frame_type = GoAway;
      }
    in
    write_frame_header t header;
    BE.write_uint32 t last_stream_id;
    BE.write_uint32 t (Error_code.serialize error_code);
    schedule_bigstring t ~off:debug_data.off ~len:debug_data.len
      debug_data.buffer

  let write_window_update_frame t stream_id increment =
    let header =
      {
        Frame.flags = Flags.default_flags;
        stream_id;
        payload_length = 4;
        frame_type = WindowUpdate;
      }
    in
    write_frame_header t header;
    BE.write_uint32 t increment
end
