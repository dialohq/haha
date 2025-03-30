open Serializes

type t = { faraday : Faraday.t; buffer : Bigstringaf.t }

let create capacity =
  let buffer = Bigstringaf.create capacity in
  { buffer; faraday = Faraday.of_bigstring buffer }

let write t socket =
  match Faraday.operation t.faraday with
  | `Close | `Yield -> ()
  | `Writev bs_list ->
      let written, cs_list =
        List.fold_left_map
          (fun acc { Faraday.buffer; off; len } ->
            (acc + len, Cstruct.of_bigarray buffer ~off ~len))
          0 bs_list
      in
      Eio.Flow.write socket cs_list;
      Faraday.shift t.faraday written

let write_settings t settings =
  let frame_info = create_frame_info Stream_identifier.connection in
  write_settings_frame t.faraday frame_info (Settings.to_settings_list settings)

let write_settings_ack t =
  let frame_info =
    create_frame_info
      ~flags:Flags.(set_ack default_flags)
      Stream_identifier.connection
  in
  write_settings_frame t.faraday frame_info Settings.(to_settings_list default)

let write_ping t payload ~(ack : bool) =
  let frame_info =
    create_frame_info
      ~flags:Flags.(if ack then set_ack default_flags else default_flags)
      Stream_identifier.connection
  in
  write_ping_frame t.faraday frame_info payload

let write_data ?(padding_length = 0) ~end_stream t stream_id total_len cs_list =
  let frame_info =
    create_frame_info
      ~flags:
        Flags.(
          if end_stream then set_end_stream default_flags else default_flags)
      ~padding_length stream_id
  in

  write_data_frame t.faraday total_len cs_list frame_info

let write_headers_response ?padding_length ?(end_header = true) t hpack_encoder
    stream_id (response : Response.t) =
  let status, headers, flags =
    match response with
    | `Interim { status; headers } ->
        ((status :> Status.t), headers, Flags.default_flags)
    | `Final { status; headers; body_writer = Some _ } ->
        (status, headers, Flags.default_flags)
    | `Final { status; headers; body_writer = None } ->
        (status, headers, Flags.default_flags |> Flags.set_end_stream)
  in

  let flags = if end_header then Flags.set_end_header flags else flags in

  let frame_info = create_frame_info ?padding_length ~flags stream_id in

  write_response_headers t.faraday hpack_encoder frame_info (Some status)
    headers

let write_trailers ?padding_length ?(end_header = true) t hpack_encoder
    stream_id headers =
  let flags =
    if end_header then
      Flags.default_flags |> Flags.set_end_header |> Flags.set_end_stream
    else Flags.default_flags |> Flags.set_end_stream
  in

  let frame_info = create_frame_info ?padding_length ~flags stream_id in

  write_response_headers t.faraday hpack_encoder frame_info None headers

let writer_request_headers ?padding_length ?(end_header = true) t hpack_encoder
    stream_id (request : Request.t) =
  let { Request.meth; path; scheme; authority; headers; body_writer; _ } =
    request
  in

  let headers =
    { Headers.name = "user-agent"; value = "haha/0.0.1" } :: headers
  in

  let end_stream = Option.is_none body_writer in
  let flags = Flags.create ~end_stream ~end_header () in
  let frame_info = create_frame_info ?padding_length ~flags stream_id in
  write_request_headers ?authority t.faraday hpack_encoder frame_info meth path
    scheme headers

let write_connection_preface t = write_connection_preface t.faraday
let write_rst_stream t = write_rst_stream_frame t.faraday
let write_goaway t = write_go_away_frame t.faraday
let write_window_update t = write_window_update_frame t.faraday
