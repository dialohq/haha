open Connection

type iteration =
  [ `End
  | `Error of Error.connection_error
  | `Shutdown of unit -> iteration
  | `InProgress of ?shutdown:bool -> unit -> iteration ]

let handle :
    ?settings:Settings.t ->
    request_handler:Reqd.handler ->
    [> Eio.Flow.two_way_ty ] Eio.Resource.t ->
    iteration =
 fun ?(settings = Settings.default) ~request_handler socket ->
  let reader = Reader.create socket Settings.default.max_frame_size in

  match Reader.(read_preface >>= read_frame) reader with
  | Ok { frame_payload = Settings lis; _ } -> (
      let peer_settings' = Settings.(update_with_list default lis) in
      let writer =
        Writer.create ~header_table_size:peer_settings'.header_table_size socket
          peer_settings'.max_frame_size
      in

      Writer.settings settings writer;
      Writer.settings_ack writer;

      match Writer.flush writer with
      | Error exn -> handle_preface_error writer (Error.Exn exn)
      | Ok () ->
          let conn =
            initial_server ~writer ~reader ~request_handler settings lis
          in
          start
            (fun streams continue ->
              `InProgress
                (fun ?(shutdown = false) () -> continue shutdown streams []))
            conn)
  | Ok _ | Error (StreamError _) ->
      let writer = Writer.create_with_defaults socket in
      handle_preface_error writer
        (Error.ProtocolViolation
           (ProtocolError, "invalid connection preface, expected SETTINGS frame"))
  | Error (ConnectionError err) ->
      let writer = Writer.create_with_defaults socket in
      handle_preface_error writer err

let connection_handler :
    ?settings:Settings.t ->
    error_handler:(Error.connection_error -> unit) ->
    Reqd.handler ->
    _ Eio.Net.connection_handler =
 fun ?settings ~error_handler request_handler socket _ ->
  let rec iterate : iteration -> unit = function
    | `End -> ()
    | `Error err -> error_handler err
    | `InProgress next -> iterate (next ())
    | `Shutdown next -> iterate (next ())
  in

  iterate (handle ?settings ~request_handler socket)
