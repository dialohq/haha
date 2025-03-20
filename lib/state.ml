type settings_sync = Syncing of Settings.t | Idle
type headers_state = Idle | InProgress of Bigstringaf.t * int

type frames_state = {
  peer_settings : Settings.t;
  local_settings : Settings.t;
  settings_status : settings_sync;
  headers_state : headers_state;
  streams : Streams.t;
  hpack_decoder : Hpack.Decoder.t;
  shutdown : bool;
  flow : Flow_control.t;
}

type preface_state = { server_settings : Settings.t; magic_received : bool }
type phase = Preface of preface_state | Frames of frames_state

type t = {
  parse_state : Parse.parse_state;
  phase : phase;
  faraday : Faraday.t;
  hpack_encoder : Hpack.Encoder.t;
}

let initial_preface_state =
  { server_settings = Settings.default; magic_received = false }

let initial_frame_state recv_setttings user_settings =
  let peer_settings = Settings.(update_with_list default recv_setttings) in
  {
    peer_settings;
    hpack_decoder = Hpack.Decoder.create 1000;
    local_settings = Settings.default;
    settings_status = Syncing user_settings;
    streams = Streams.initial;
    shutdown = false;
    headers_state = Idle;
    flow = Flow_control.initial;
  }

let search_for_writes frames_state =
  Streams.get_user_writes frames_state.streams
