open Connection

type iteration =
  [ `End
  | `Error of Error.connection_error
  | `Shutdown of unit -> iteration
  | `InProgress of ?shutdown:bool -> Request.t list -> iteration ]

let rec write_requests streams writes = function
  | [] -> (streams, writes)
  | request :: rest ->
      let streams, new_writes = Streams.write_request ~request streams in
      write_requests streams (writes @ new_writes) rest

let connect :
    ?settings:Settings.t -> [> Eio.Flow.two_way_ty ] Eio.Resource.t -> iteration
    =
 fun ?(settings = Settings.default) socket ->
  let writer = Writer.create_with_defaults socket in

  Writer.connection_preface writer;
  Writer.settings settings writer;

  match Writer.flush writer with
  | Error exn -> handle_preface_error writer (Exn exn)
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
          start
            (fun streams continue ->
              `InProgress
                (fun ?(shutdown = false) requests ->
                  let new_streams, writes =
                    write_requests streams [] requests
                  in
                  continue shutdown new_streams writes))
            conn
      | Ok _ | Error (StreamError _) ->
          handle_preface_error writer
            (Error.ProtocolViolation
               ( ProtocolError,
                 "invalid connection preface, expected SETTINGS frame" ))
      | Error (ConnectionError err) -> handle_preface_error writer err)
