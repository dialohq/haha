open Connection

let connect :
    ?settings:Settings.t -> [> Eio.Flow.two_way_ty ] Eio.Resource.t -> iteration
    =
 fun ?(settings = Settings.default) socket ->
  let writer = Writer.create_with_defaults socket in

  Writer.connection_preface writer;
  Writer.settings settings writer;

  match Writer.flush writer with
  | Error exn -> Error (Exn exn)
  | Ok () -> (
      let reader = Reader.create socket Settings.default.max_frame_size in

      match Reader.read_frame reader with
      | Ok { frame_payload = Settings lis; _ } ->
          let peer_settings' = Settings.(update_with_list default lis) in
          let writer =
            Writer.create ~header_table_size:peer_settings'.header_table_size
              socket peer_settings'.max_frame_size
          in
          Writer.settings_ack writer;

          let conn = initial_client ~writer ~reader settings lis in
          start conn
      | Ok _ | Error (StreamError _) ->
          handle_preface_error writer
            (Error.ProtocolViolation
               ( ProtocolError,
                 "invalid connection preface, expected SETTINGS frame" ))
      | Error (ConnectionError err) -> handle_preface_error writer err)
