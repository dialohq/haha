type settings_sync = Syncing of Settings.t | Idle
type headers_state = Idle | InProgress of Bigstringaf.t * int

type ('readers, 'writers) state = {
  peer_settings : Settings.t;
  local_settings : Settings.t;
  settings_status : settings_sync;
  headers_state : headers_state;
  streams : ('readers, 'writers) Streams.t;
  hpack_encoder : Hpackv.Encoder.t;
  hpack_decoder : Hpackv.Decoder.t;
  shutdown : bool;
  writer : Writer.t;
  parse_state : Parse.continue option;
  flow : Flow_control.t;
}

let initial ~writer ~peer_settings ~user_settings =
  {
    peer_settings;
    writer;
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
    parse_state = None;
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
