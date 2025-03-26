open Flow_control

type setting =
  | HeaderTableSize of int
  | EnablePush of int
  | MaxConcurrentStreams of int32
  | InitialWindowSize of int32
  | MaxFrameSize (* this means payload size *) of int
  | MaxHeaderListSize of int

type settings_list = setting list

let octets_per_setting = 6
let minimal_frame_size_allowed = 0x4000

let serialize_key = function
  | HeaderTableSize _ -> 0x1
  | EnablePush _ -> 0x2
  | MaxConcurrentStreams _ -> 0x3
  | InitialWindowSize _ -> 0x4
  | MaxFrameSize _ -> 0x5
  | MaxHeaderListSize _ -> 0x6

type t = {
  header_table_size : int;
  enable_push : bool;
  max_concurrent_streams : int32;
  initial_window_size : WindowSize.t;
  max_frame_size : int;
  max_header_list_size : int option;
}

let default =
  {
    header_table_size = 0x1000;
    enable_push = true;
    max_concurrent_streams = Int32.max_int;
    initial_window_size = WindowSize.default_initial_window_size;
    max_frame_size = minimal_frame_size_allowed;
    max_header_list_size = None;
  }

let to_settings_list settings =
  let settings_list =
    if settings.max_frame_size <> default.max_frame_size then
      [ MaxFrameSize settings.max_frame_size ]
    else []
  in
  let settings_list =
    if settings.max_concurrent_streams <> default.max_concurrent_streams then
      MaxConcurrentStreams settings.max_concurrent_streams :: settings_list
    else settings_list
  in
  let settings_list =
    if settings.initial_window_size <> default.initial_window_size then
      (* FIXME: don't convert *)
      InitialWindowSize settings.initial_window_size :: settings_list
    else settings_list
  in
  let settings_list =
    if settings.enable_push <> default.enable_push then
      EnablePush (if settings.enable_push then 1 else 0) :: settings_list
    else settings_list
  in
  settings_list

let write_settings_payload t settings_list =
  let open Faraday in
  List.iter
    (fun setting ->
      (* From RFC7540§6.5.1:
       *   The payload of a SETTINGS frame consists of zero or more parameters,
       *   each consisting of an unsigned 16-bit setting identifier and an
       *   unsigned 32-bit value. *)
      BE.write_uint16 t (serialize_key setting);
      match setting with
      | MaxConcurrentStreams value | InitialWindowSize value ->
          BE.write_uint32 t value
      | HeaderTableSize value
      | EnablePush value
      | MaxFrameSize value
      | MaxHeaderListSize value ->
          BE.write_uint32 t (Int32.of_int value))
    settings_list

let update_with_list settings new_settings =
  List.fold_left
    (fun (acc : t) item ->
      match item with
      | HeaderTableSize x -> { acc with header_table_size = x }
      | EnablePush x -> { acc with enable_push = x = 1 }
      | MaxConcurrentStreams x -> { acc with max_concurrent_streams = x }
      | InitialWindowSize new_val -> { acc with initial_window_size = new_val }
      | MaxFrameSize x -> { acc with max_frame_size = x }
      | MaxHeaderListSize x -> { acc with max_header_list_size = Some x })
    settings new_settings

let pp_hum formatter t =
  let pp_elem formatter setting =
    let key, value =
      match setting with
      | HeaderTableSize v -> ("HEADER_TABLE_SIZE", Int64.of_int v)
      | EnablePush v -> ("ENABLE_PUSH", Int64.of_int v)
      | MaxConcurrentStreams v -> ("MAX_CONCURRENT_STREAMS", Int64.of_int32 v)
      | InitialWindowSize v -> ("INITIAL_WINDOW_SIZE", Int64.of_int32 v)
      | MaxFrameSize v -> ("MAX_FRAME_SIZE", Int64.of_int v)
      | MaxHeaderListSize v -> ("MAX_HEADER_LIST_SIZE", Int64.of_int v)
    in
    Format.fprintf formatter "@[(%S %Ld)@]" key value
  in
  Format.fprintf formatter "@[(";
  Format.pp_print_list pp_elem formatter (to_settings_list t);
  Format.fprintf formatter ")@]"
