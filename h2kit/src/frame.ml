module Bigstringaf = struct
  include Bigstringaf

  let pp fmt b = Format.fprintf fmt "%S" (to_string b)

  let equal b1 b2 =
    Cstruct.equal (Cstruct.of_bigarray b1) (Cstruct.of_bigarray b2)
end

module Cstruct = struct
  include Cstruct

  let pp fmt b = Format.fprintf fmt "%S" (to_string b)
end

let connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

module FrameType = struct
  type t =
    | Data
    | Headers
    | Priority
    | RSTStream
    | Settings
    | PushPromise
    | Ping
    | GoAway
    | WindowUpdate
    | Continuation
    | Unknown of int
  [@@deriving show { with_path = false }, eq]

  let to_int = function
    | Data -> 0
    | Headers -> 1
    | Priority -> 2
    | RSTStream -> 3
    | Settings -> 4
    | PushPromise -> 5
    | Ping -> 6
    | GoAway -> 7
    | WindowUpdate -> 8
    | Continuation -> 9
    | Unknown x -> x

  let of_int = function
    | 0 -> Data
    | 1 -> Headers
    | 2 -> Priority
    | 3 -> RSTStream
    | 4 -> Settings
    | 5 -> PushPromise
    | 6 -> Ping
    | 7 -> GoAway
    | 8 -> WindowUpdate
    | 9 -> Continuation
    | x -> Unknown x

  let pp_hum fmt p =
    Format.fprintf fmt
      (match p with
      | Data -> "DATA"
      | Headers -> "HEADERS"
      | Priority -> "PRIORITY"
      | RSTStream -> "RSTSTREAM"
      | Settings -> "SETTINGS"
      | PushPromise -> "PUSH_PROMISE"
      | Ping -> "PING"
      | GoAway -> "GOAWAY"
      | WindowUpdate -> "WINDOW_UPDATE"
      | Continuation -> "CONTINUATION"
      | Unknown _ -> "UNKNOWN")
end

type frame_header = {
  payload_length : int;
  flags : Flags.t;
  stream_id : Stream_identifier.t;
  frame_type : FrameType.t;
}
[@@deriving show, eq]

type frame_payload =
  | Data of Cstruct.t
  | Headers of Bigstringaf.t
  | Priority
  | RSTStream of Error_code.t
  | Settings of Settings.setting list
  | PushPromise of Stream_identifier.t * Bigstringaf.t
  | Ping of Bigstringaf.t
  | GoAway of (Stream_identifier.t * Error_code.t * Bigstringaf.t)
  | WindowUpdate of Window_size.t
  | Continuation of Bigstringaf.t
  | Unknown of int * Bigstringaf.t
[@@deriving show { with_path = false }, eq]

type t = { frame_header : frame_header; frame_payload : frame_payload }
[@@deriving show, eq]

let validate_header
    ({ frame_type; payload_length; flags; stream_id } : frame_header) :
    (unit, Error.t) result =
  let open Stream_identifier in
  let conn_error code msg = Error (Error.conn_prot_err code msg) in
  let stream_error id code = Error (Error.stream_prot_err id code) in

  match frame_type with
  | Settings ->
      if not (is_connection stream_id) then
        conn_error ProtocolError
          "SETTINGS must be associated with stream id 0x0"
      else if payload_length mod 6 <> 0 then
        conn_error FrameSizeError
          "SETTINGS payload size must be a multiple of 6"
      else if Flags.test_ack flags && payload_length <> 0 then
        conn_error FrameSizeError "SETTINGS with ACK must be empty"
      else Ok ()
  | Ping ->
      if not (is_connection stream_id) then
        conn_error ProtocolError "PING must be associated with stream id 0x0"
      else if payload_length <> 8 then
        conn_error FrameSizeError "PING payload must be 8 octets in length"
      else Ok ()
  | Headers ->
      if is_connection stream_id then
        conn_error ProtocolError "HEADERS must be associated with a stream"
      else if is_server stream_id then
        conn_error ProtocolError
          "HEADERS must have a odd-numbered stream identifier"
      else Ok ()
  | Data ->
      if is_connection stream_id then
        conn_error ProtocolError "DATA frames must be associated with a stream"
      else Ok ()
  | PushPromise ->
      if is_connection stream_id then
        conn_error ProtocolError "PUSH_PROMISE must be associated with a stream"
      else Ok ()
  | GoAway ->
      if not (is_connection stream_id) then
        conn_error ProtocolError "GOAWAY must be associated with stream id 0x0"
      else Ok ()
  | RSTStream ->
      if is_connection stream_id then
        conn_error ProtocolError "RST_STREAM must be associated with a stream"
      else if payload_length <> 4 then
        conn_error FrameSizeError
          "RST_STREAM payload must be 4 octets in length"
      else Ok ()
  | Priority ->
      if is_connection stream_id then
        conn_error ProtocolError "PRIORITY must be associated with a stream"
      else if payload_length <> 5 then stream_error stream_id FrameSizeError
      else Ok ()
  | WindowUpdate ->
      if payload_length <> 4 then
        conn_error FrameSizeError
          "WINDOW_UPDATE payload must be 4 octets in length"
      else Ok ()
  | Continuation ->
      if is_connection stream_id then
        conn_error ProtocolError "CONTINUATION must be associated with a stream"
      else Ok ()
  | Unknown _ -> Ok ()

let pp_hum fmt t =
  Format.fprintf fmt "%a [%li]" FrameType.pp_hum t.frame_header.frame_type
    t.frame_header.stream_id
