type settings_sync = Syncing of Settings.settings_list | Idle
type headers_state = Idle | InProgress of Bigstringaf.t * int

type ('readers, 'writers) t = {
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
    settings_status = Syncing Settings.(to_settings_list user_settings);
    streams = Streams.initial ();
    shutdown = false;
    headers_state = Idle;
    parse_state = None;
    flow = Flow_control.initial;
  }

let combine ~combine_streams s1 s2 =
  {
    s1 with
    flow = Flow_control.max s1.flow s2.flow;
    streams = combine_streams s1.streams s2.streams;
    parse_state =
      (match (s1.parse_state, s2.parse_state) with
      | Some x, Some y when x == y -> Some x
      | Some _, Some _ -> failwith "gowno"
      | Some x, None -> Some x
      | None, Some x -> Some x
      | None, None -> None);
  }

let update_state_with_peer_settings (t : ('a, 'b) t) settings_list =
  let rec loop list (state : ('a, 'b) t) : (('a, 'b) t, string) result =
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

let update_state_with_local_settings (t : ('a, 'b) t) settings_list =
  let rec loop list (state : ('a, 'b) t) : (('a, 'b) t, string) result =
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

let pp_hum_generic fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "peer_settings = %a;" Settings.pp_hum t.peer_settings;
  fprintf fmt "@ local_settings = %a;" Settings.pp_hum t.local_settings;
  fprintf fmt "@ settings_status = ";
  (match t.settings_status with
  | Syncing settings_list ->
      fprintf fmt "Syncing <length %i>" (List.length settings_list)
  | Idle -> fprintf fmt "Idle");
  fprintf fmt ";";
  fprintf fmt "@ headers_state = ";
  (match t.headers_state with
  | Idle -> fprintf fmt "Idle"
  | InProgress (_, n) -> fprintf fmt "InProgress (<bigstring>, %d)" n);
  fprintf fmt ";";
  fprintf fmt "@ streams = %a;" Streams.pp_hum_generic t.streams;
  fprintf fmt "@ shutdown = %b;" t.shutdown;
  fprintf fmt "@ writer = %a;" Writer.pp_hum t.writer;
  fprintf fmt "@ parse_state = %s;"
    (match t.parse_state with Some _ -> "Some" | None -> "None");
  fprintf fmt "@ flow = %a" Flow_control.pp_hum t.flow;
  fprintf fmt "@]}"

let pp_hum pp_readers pp_writers fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "peer_settings = %a;" Settings.pp_hum t.peer_settings;
  fprintf fmt "@ local_settings = %a;" Settings.pp_hum t.local_settings;
  fprintf fmt "@ settings_status = ";
  (match t.settings_status with
  | Syncing settings_list ->
      fprintf fmt "Syncing <length %i>" (List.length settings_list)
  | Idle -> fprintf fmt "Idle");
  fprintf fmt ";";
  fprintf fmt "@ headers_state = ";
  (match t.headers_state with
  | Idle -> fprintf fmt "Idle"
  | InProgress (_, n) -> fprintf fmt "InProgress (<bigstring>, %d)" n);
  fprintf fmt ";";
  fprintf fmt "@ streams = %a;" (Streams.pp_hum pp_readers pp_writers) t.streams;
  fprintf fmt "@ shutdown = %b;" t.shutdown;
  fprintf fmt "@ writer = %a;" Writer.pp_hum t.writer;
  fprintf fmt "@ parse_state = %s;"
    (match t.parse_state with Some _ -> "Some" | None -> "None");
  fprintf fmt "@ flow = %a" Flow_control.pp_hum t.flow;
  fprintf fmt "@]}"
