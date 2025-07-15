open H2kit

type t =
  | Frame of Frame.t
  | Malformed
  | ValidationFailed of Error.t
  | Magic
  | EOF
  | Timeout
[@@deriving show]

type matcher = t -> (unit, string) result

let magic : matcher = function
  | Magic -> Ok ()
  | _ -> Error "client preface magic string"

let eof : matcher = function EOF -> Ok () | _ -> Error "EOF"

let settings : matcher = function
  | Frame { frame_payload = Settings _; _ } -> Ok ()
  | _ -> Error "SETTINGS frame"

let settings_ack : matcher = function
  | Frame { frame_header = { frame_type = Settings; flags; _ }; _ }
    when Flags.test_ack flags ->
      Ok ()
  | _ -> Error "SETTINGS frame with ACK flag set"

let frame_header ?flags ?id typ : matcher = function
  | Frame { frame_header = { flags = fl; stream_id; frame_type; _ }; _ } ->
      let flags_cond =
        match flags with None -> true | Some flags -> flags = fl
      in
      let id_cond = match id with None -> true | Some id -> id = stream_id in

      let type_cond = typ = frame_type in

      if flags_cond && id_cond && type_cond then Ok ()
      else Error (Format.asprintf "%s frame" (Frame.FrameType.to_string typ))
  | _ -> Error (Format.asprintf "%s frame" (Frame.FrameType.to_string typ))

let goaway : matcher = function
  | Frame { frame_payload = GoAway _; _ } -> Ok ()
  | _ -> Error "GOAWAY frame"

let goaway_code code : matcher = function
  | Frame { frame_payload = GoAway (_, code', _); _ } when code = code' -> Ok ()
  | _ ->
      Error
        (Format.asprintf "GOAWAY frame with code %s"
           (Error_code.to_string code))

let headers : matcher = function
  | Frame { frame_payload = Headers _; _ } -> Ok ()
  | _ -> Error "HEADERS frame"

let data = function
  | Frame { frame_payload = Data _; _ } -> Ok ()
  | _ -> Error "DATA frame"

let ping = function
  | Frame { frame_payload = Ping _; _ } -> Ok ()
  | _ -> Error "PING frame"

let ping_p cs = function
  | Frame { frame_payload = Ping cs'; _ } when Cstruct.of_string cs = cs' ->
      Ok ()
  | _ -> Error "PING frame"

let stream_error id code = function
  | Frame { frame_payload = RSTStream code'; frame_header = { stream_id; _ } }
    when code = code' && id = stream_id ->
      Ok ()
  | Frame { frame_payload = RSTStream code'; _ } when code = code' ->
      Error (Format.asprintf "RST_STREAM frame on stream %li" id)
  | Frame { frame_header = { frame_type = RSTStream; stream_id; _ }; _ }
    when id = stream_id ->
      Error
        (Format.asprintf "RST_STREAM frame with code %s"
           (Error_code.to_string code))
  | _ ->
      Error
        (Format.asprintf "RST_STREAM frame on stream %li with code %s" id
           (Error_code.to_string code))

let timeout : matcher = function
  | Timeout -> Ok ()
  | _ -> Error "time delay before next frame"
