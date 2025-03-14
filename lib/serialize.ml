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

let write_data ?(padding_length = 0) f bs ~off ~len stream_id end_stream =
  let frame_info =
    create_frame_info
      ~flags:
        Flags.(
          if end_stream then set_end_stream default_flags else default_flags)
      ~padding_length stream_id
  in

  write_data_frame f ~off ~len frame_info bs

let write_headers_response ?padding_length f hpack_encoder stream_id
    ~end_headers response =
  let flags =
    match (response.Response.end_stream, end_headers) with
    | true, true -> Flags.(default_flags |> set_end_stream |> set_end_header)
    | false, true -> Flags.(default_flags |> set_end_header)
    | true, false -> Flags.(default_flags |> set_end_stream)
    | false, false -> Flags.default_flags
  in

  let frame_info = create_frame_info ?padding_length ~flags stream_id in

  write_response_headers f hpack_encoder frame_info response

let write_rst_stream = write_rst_stream_frame
let write_goaway = write_go_away_frame
let write_window_update = Serializes.write_window_update_frame
