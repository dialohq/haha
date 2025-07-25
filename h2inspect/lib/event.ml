open H2kit

type t =
  | Frame of Frame.t
  | Malformed
  | ValidationFailed of Error.t
  | Magic
  | EOF
  | Timeout
[@@deriving show]

type 'a matcher = t -> ('a, string) result

let magic : unit matcher = function
  | Magic -> Ok ()
  | _ -> Error "client preface magic string"

let eof : unit matcher = function EOF -> Ok () | _ -> Error "EOF"

let settings : Settings.setting list matcher = function
  | Frame { frame_payload = Settings l; _ } -> Ok l
  | _ -> Error "SETTINGS frame"

let settings_ack : Settings.setting list matcher = function
  | Frame
      {
        frame_header = { frame_type = Settings; flags; _ };
        frame_payload = Settings l;
      }
    when Flags.test_ack flags ->
      Ok l
  | _ -> Error "SETTINGS frame with ACK flag set"

let frame_header ?flags ?id typ : Frame.frame_header matcher = function
  | Frame
      { frame_header = { flags = fl; stream_id; frame_type; _ } as header; _ }
    ->
      let flags_cond =
        match flags with None -> true | Some flags -> flags = fl
      in
      let id_cond = match id with None -> true | Some id -> id = stream_id in

      let type_cond = typ = frame_type in

      if flags_cond && id_cond && type_cond then Ok header
      else Error (Format.asprintf "%s frame" (Frame.FrameType.to_string typ))
  | _ -> Error (Format.asprintf "%s frame" (Frame.FrameType.to_string typ))

let goaway : (int32 * Error_code.t * Bigstringaf.t) matcher = function
  | Frame { frame_payload = GoAway p; _ } -> Ok p
  | _ -> Error "GOAWAY frame"

let goaway_code code : _ matcher = function
  | Frame { frame_payload = GoAway (_, code', _); _ } when code = code' ->
      Ok code'
  | _ ->
      Error
        (Format.asprintf "GOAWAY frame with code %s"
           (Error_code.to_string code))

let headers : _ matcher = function
  | Frame { frame_payload = Headers _; _ } -> Ok ()
  | _ -> Error "HEADERS frame"

let data : Cstruct.t matcher = function
  | Frame { frame_payload = Data cs; _ } -> Ok cs
  | _ -> Error "DATA frame"

let ping : unit matcher = function
  | Frame { frame_payload = Ping _; _ } -> Ok ()
  | _ -> Error "PING frame"

let ping_p cs : unit matcher = function
  | Frame { frame_payload = Ping cs'; _ } when Cstruct.of_string cs = cs' ->
      Ok ()
  | _ -> Error "PING frame"

let stream_error id code : unit matcher = function
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

let timeout : unit matcher = function
  | Timeout -> Ok ()
  | _ -> Error "time delay before next frame"

let pp_hum_short fmt =
  let open Format in
  function
  | Frame frame -> fprintf fmt "%a" Frame.pp_hum_short frame
  | Malformed -> fprintf fmt "Malformed Frame!"
  | ValidationFailed _ -> fprintf fmt "Malformed Frame!"
  | Magic -> fprintf fmt "MAGIC"
  | EOF -> fprintf fmt "EOF"
  | Timeout -> fprintf fmt "TIMEOUT"
