open Serializers.Make (Faraday)

type t = {
  faraday : Faraday.t;
  buffer : Bigstringaf.t;
  hpack_encoder : Hpack.Encoder.t;
}

type writer = t -> unit
type _ Effect.t += Write : writer -> unit Effect.t

let write writer = Effect.perform (Write writer)

let create ~header_table_size capacity =
  let buffer = Bigstringaf.create capacity in

  let hpack_encoder =
    Hpack.Encoder.create
      (Int.min header_table_size Settings.default.header_table_size)
  in
  { buffer; faraday = Faraday.of_bigstring buffer; hpack_encoder }

let set_encoder_capacity t = Hpack.Encoder.set_capacity t.hpack_encoder

let flush t socket =
  let op = Faraday.operation t.faraday in
  match op with
  | `Close -> Ok ()
  | `Yield -> Ok ()
  | `Writev bs_list -> (
      let written, cs_list =
        List.fold_left_map
          (fun acc { Faraday.buffer; off; len } ->
            (acc + len, Cstruct.of_bigarray buffer ~off ~len))
          0 bs_list
      in
      try
        Eio.Flow.write socket cs_list;

        Faraday.shift t.faraday written;
        Ok ()
      with exn -> Error exn)

let connection_preface t = write_connection_preface t.faraday

let goaway ?debug_data id code t =
  write_goaway_frame ?debug_data id code t.faraday

let window_update ~increment id t =
  write_window_update_frame id increment t.faraday

let settings settings t =
  let frame_info = create_frame_info Stream_identifier.connection in
  write_settings_frame (Settings.to_settings_list settings) frame_info t.faraday

let settings_ack t =
  let frame_info =
    create_frame_info
      ~flags:Flags.(set_ack default_flags)
      Stream_identifier.connection
  in
  write_settings_frame Settings.(to_settings_list default) frame_info t.faraday

let ping ?(ack = false) payload t =
  let frame_info =
    create_frame_info
      ~flags:Flags.(if ack then set_ack default_flags else default_flags)
      Stream_identifier.connection
  in
  write_ping_frame payload frame_info t.faraday

let data ?(padding_length = 0) ?(end_stream = false) stream_id cs_list t =
  let frame_info =
    create_frame_info
      ~flags:
        Flags.(
          if end_stream then set_end_stream default_flags else default_flags)
      ~padding_length stream_id
  in

  write_data_frame cs_list frame_info t.faraday

let response_headers ?padding_length ?(end_header = true) stream_id
    (response : _ Response.t) t =
  let status, headers, flags =
    match response with
    | `Interim { status; headers; _ } ->
        ((status :> Status.t), headers, Flags.default_flags)
    | `Final { status; headers; body_writer = Some _; _ } ->
        (status, headers, Flags.default_flags)
    | `Final { status; headers; body_writer = None; _ } ->
        (status, headers, Flags.default_flags |> Flags.set_end_stream)
  in

  let headers =
    Headers.join
      [ Headers.of_list [ (":status", Status.to_string status) ]; headers ]
  in

  let flags = if end_header then Flags.set_end_header flags else flags in

  let frame_info = create_frame_info ?padding_length ~flags stream_id in

  write_headers_frame t.hpack_encoder headers frame_info t.faraday

let haha_header = ("user-agent", "haha/0.0.1")

let request_headers ?padding_length ?(end_header = true) stream_id
    (request : Request.t) t =
  let (Request { meth; path; scheme; authority; headers; body_writer; _ }) =
    request
  in

  let request_headers =
    match authority with
    | Some authority ->
        Headers.of_list
          [
            (":method", Method.to_string meth);
            (":path", path);
            (":scheme", scheme);
            (":authority", authority);
            haha_header;
          ]
    | None ->
        Headers.of_list
          [
            (":method", Method.to_string meth);
            (":path", path);
            (":scheme", scheme);
            haha_header;
          ]
  in
  let headers = Headers.join [ request_headers; headers ] in

  let end_stream = Option.is_none body_writer in
  let flags = Flags.create ~end_stream ~end_header () in
  let frame_info = create_frame_info ?padding_length ~flags stream_id in
  write_headers_frame t.hpack_encoder headers frame_info t.faraday

let trailers ?padding_length ?(end_header = true) stream_id headers t =
  let flags =
    if end_header then
      Flags.default_flags |> Flags.set_end_header |> Flags.set_end_stream
    else Flags.default_flags |> Flags.set_end_stream
  in

  let frame_info = create_frame_info ?padding_length ~flags stream_id in

  write_headers_frame t.hpack_encoder headers frame_info t.faraday

let rst_stream id code t = write_rst_stream_frame id code t.faraday

let pp_hum fmt t =
  Format.fprintf fmt "<length %i>" (Bigstringaf.length t.buffer)
