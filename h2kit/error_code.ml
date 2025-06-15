type t =
  | NoError
  | ProtocolError
  | InternalError
  | FlowControlError
  | SettingsTimeout
  | StreamClosed
  | FrameSizeError
  | RefusedStream
  | Cancel
  | CompressionError
  | ConnectError
  | EnhanceYourCalm
  | InadequateSecurity
  | HTTP_1_1_Required
  | UnknownError_code of int32

let serialize = function
  | NoError -> 0x0l
  | ProtocolError -> 0x1l
  | InternalError -> 0x2l
  | FlowControlError -> 0x3l
  | SettingsTimeout -> 0x4l
  | StreamClosed -> 0x5l
  | FrameSizeError -> 0x6l
  | RefusedStream -> 0x7l
  | Cancel -> 0x8l
  | CompressionError -> 0x9l
  | ConnectError -> 0xal
  | EnhanceYourCalm -> 0xbl
  | InadequateSecurity -> 0xcl
  | HTTP_1_1_Required -> 0xdl
  | UnknownError_code id -> id

let parse = function
  | 0x0l -> NoError
  | 0x1l -> ProtocolError
  | 0x2l -> InternalError
  | 0x3l -> FlowControlError
  | 0x4l -> SettingsTimeout
  | 0x5l -> StreamClosed
  | 0x6l -> FrameSizeError
  | 0x7l -> RefusedStream
  | 0x8l -> Cancel
  | 0x9l -> CompressionError
  | 0xal -> ConnectError
  | 0xbl -> EnhanceYourCalm
  | 0xcl -> InadequateSecurity
  | 0xdl -> HTTP_1_1_Required
  | id -> UnknownError_code id

let to_string = function
  | NoError -> "NO_ERROR (0x0)"
  | ProtocolError -> "PROTOCOL_ERROR (0x1)"
  | InternalError -> "INTERNAL_ERROR (0x2)"
  | FlowControlError -> "FLOW_CONTROL_ERROR (0x3)"
  | SettingsTimeout -> "SETTINGS_TIMEOUT (0x4)"
  | StreamClosed -> "STREAM_CLOSED (0x5)"
  | FrameSizeError -> "FRAME_SIZE_ERROR (0x6)"
  | RefusedStream -> "REFUSED_STREAM (0x7)"
  | Cancel -> "CANCEL (0x8)"
  | CompressionError -> "COMPRESSION_ERROR (0x9)"
  | ConnectError -> "CONNECT_ERROR (0xa)"
  | EnhanceYourCalm -> "ENHANCE_YOUR_CALM (0xb)"
  | InadequateSecurity -> "INADEQUATE_SECURITY (0xc)"
  | HTTP_1_1_Required -> "HTTP_1_1_REQUIRED (0xd)"
  | UnknownError_code id -> Format.asprintf "UNKNOWN_ERROR (0x%lx)" id

let pp_hum formatter t = Format.fprintf formatter "%s" (to_string t)
