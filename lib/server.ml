open Connection

let handle :
    ?settings:Settings.t ->
    request_handler:Reqd.handler ->
    [> Eio.Flow.two_way_ty ] Eio.Resource.t ->
    iteration =
 fun ?(settings = Settings.default) ~request_handler socket ->
  let reader = Reader.create socket settings.max_frame_size in

  let conn =
    match Reader.(read_preface >>= read_frame) reader with
    | Ok { frame_payload = Settings lis; _ } -> (
        let peer_settings' = Settings.(update_with_list default lis) in
        let writer =
          Writer.create ~header_table_size:peer_settings'.header_table_size
            socket peer_settings'.max_frame_size
        in

        Writer.settings settings writer;

        match Writer.flush writer with
        | Error exn -> Result.Error (Error.Exn exn)
        | Ok () ->
            let conn =
              initial_server ~writer ~reader ~request_handler settings lis
            in
            Ok conn)
    | Ok _ | Error (StreamError _) ->
        Error
          (Error.ProtocolViolation
             ( ProtocolError,
               "invalid connection preface, expected SETTINGS frame" ))
    | Error (ConnectionError err) -> Error err
  in

  start conn

let connection_handler :
    ?settings:Settings.t ->
    error_handler:(Error.connection_error -> unit) ->
    Reqd.handler ->
    _ Eio.Net.connection_handler =
 fun ?settings ~error_handler request_handler socket _ ->
  let rec iterate : iteration -> unit = function
    | End -> ()
    | Error err -> error_handler err
    | InProgress next -> iterate (next ())
  in

  iterate (handle ?settings ~request_handler socket)
