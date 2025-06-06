type settings_sync = Syncing of Settings.settings_list | Idle
type headers_state = Idle | InProgress of Bigstringaf.t * int
type 'context final_contexts = (Stream_identifier.t * 'context) list

type 'peer t = {
  peer_settings : Settings.t;
  local_settings : Settings.t;
  settings_status : settings_sync;
  headers_state : headers_state;
  streams : 'peer Streams.t;
  hpack_encoder : Hpackv.Encoder.t;
  hpack_decoder : Hpackv.Decoder.t;
  shutdown : bool;
  writer : Writer.t;
  parse_state : Parse.continue option;
  flow : Flow_control.t;
  read_off : int;
  flush_thunk : unit -> unit;
  prev_iter_ignore : Stream_identifier.t list;
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
    settings_status = Syncing Settings.(to_settings_list user_settings);
    streams = Streams.initial ();
    shutdown = false;
    headers_state = Idle;
    parse_state = None;
    flow = Flow_control.initial;
    read_off = 0;
    flush_thunk = ignore;
    prev_iter_ignore = [];
  }

let active_streams t = Streams.count_active t.streams
let error_all err t = Streams.error_all err t.streams

let do_flush t =
  t.flush_thunk ();
  { t with flush_thunk = ignore }

let update_state_with_peer_settings (t : _ t) settings_list =
  let rec loop list (state : _ t) : (_ t, string) result =
    match list with
    | [] -> Ok state
    | Settings.HeaderTableSize x :: l -> (
        match
          Result.map
            (fun _ -> state)
            (Hpackv.Decoder.set_capacity state.hpack_decoder x)
        with
        | Error _ -> Error "error updating HPack decoder capacity"
        | Ok state -> loop l state)
    | MaxFrameSize _ :: l -> loop l state
    | MaxHeaderListSize _ :: l -> loop l state
    | _ :: l -> loop l state
  in

  loop settings_list
    { t with peer_settings = Settings.(update_with_list default settings_list) }

let update_state_with_local_settings (t : _ t) settings_list =
  let rec loop list (state : _ t) : (_ t, string) result =
    match list with
    | [] -> Ok state
    | Settings.HeaderTableSize x :: l ->
        Hpackv.Encoder.set_capacity state.hpack_encoder x;
        loop l state
    | MaxFrameSize _ :: l -> loop l state
    | MaxHeaderListSize _ :: l -> loop l state
    | _ :: l -> loop l state
  in

  loop settings_list
    {
      t with
      local_settings = Settings.(update_with_list default settings_list);
    }
