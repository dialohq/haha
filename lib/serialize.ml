open Serializes

let write_settings f settings =
  let frame_info = create_frame_info Stream_identifier.connection in
  write_settings_frame f frame_info (Settings.to_settings_list settings)

let write_settings_ack f =
  let frame_info =
    create_frame_info
      ~flags:Flags.(set_ack default_flags)
      Stream_identifier.connection
  in
  write_settings_frame f frame_info Settings.(to_settings_list default)

let write_ping f payload ~(ack : bool) =
  let frame_info =
    create_frame_info
      ~flags:Flags.(if ack then set_ack default_flags else default_flags)
      Stream_identifier.connection
  in
  write_ping_frame f frame_info payload

let write_data ?(padding_length = 0) ~end_stream f bs ~off ~len stream_id =
  let frame_info =
    create_frame_info
      ~flags:
        Flags.(
          if end_stream then set_end_stream default_flags else default_flags)
      ~padding_length stream_id
  in

  write_data_frame f ~off ~len frame_info bs

let write_headers_response ?padding_length ?(end_header = true) f hpack_encoder
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

  write_response_headers f hpack_encoder frame_info (Some status) headers

let write_trailers ?padding_length ?(end_header = true) f hpack_encoder
    stream_id headers =
  let flags =
    if end_header then
      Flags.default_flags |> Flags.set_end_header |> Flags.set_end_stream
    else Flags.default_flags |> Flags.set_end_stream
  in

  let frame_info = create_frame_info ?padding_length ~flags stream_id in

  write_response_headers f hpack_encoder frame_info None headers

let write_rst_stream = write_rst_stream_frame
let write_goaway = write_go_away_frame
let write_window_update = Serializes.write_window_update_frame
