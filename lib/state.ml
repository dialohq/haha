type settings_sync = Syncing of Settings.t | Idle
type headers_state = Idle | InProgress of Bigstringaf.t * int

type ('readers, 'writers) frames_state = {
  peer_settings : Settings.t;
  local_settings : Settings.t;
  settings_status : settings_sync;
  headers_state : headers_state;
  streams : ('readers, 'writers) Streams.t;
  hpack_encoder : Hpackv.Encoder.t;
  hpack_decoder : Hpackv.Decoder.t;
  shutdown : bool;
  flow : Flow_control.t;
}

type ('readers, 'writers) phase =
  | Preface of bool
  | Frames of ('readers, 'writers) frames_state

type ('readers, 'writers) t = {
  parse_state : Parse.parse_state;
  phase : ('readers, 'writers) phase;
  faraday : Faraday.t;
}

let initial_frame_state recv_setttings user_settings =
  let peer_settings = Settings.(update_with_list default recv_setttings) in
  {
    peer_settings;
    hpack_decoder =
      Hpackv.Decoder.create
        (Int.min peer_settings.header_table_size
           Settings.default.header_table_size);
    hpack_encoder =
      Hpackv.Encoder.create
        (Int.min peer_settings.header_table_size
           Settings.default.header_table_size);
    local_settings = Settings.default;
    settings_status = Syncing user_settings;
    streams = Streams.initial ();
    shutdown = false;
    headers_state = Idle;
    flow = Flow_control.initial;
  }

let update_hpack_capacity state =
  match
    Hpackv.Decoder.set_capacity state.hpack_decoder
      (Int.min state.peer_settings.header_table_size
         state.local_settings.header_table_size)
  with
  | Error _ as err -> err
  | Ok _ -> (
      match
        Hpackv.Decoder.set_capacity state.hpack_decoder
          (Int.min state.peer_settings.header_table_size
             state.local_settings.header_table_size)
      with
      | Error _ as err -> err
      | Ok _ -> Ok ())

let initial () =
  {
    phase = Preface false;
    parse_state = Magic;
    faraday = Faraday.create Settings.default.max_frame_size;
  }
