type t = {
  header_table_size : int;
  enable_push : bool;
  max_concurrent_streams : int32;
  initial_window_size : Window_size.t;
  max_frame_size : int;
  max_header_list_size : int option;
}

let octets_per_setting = 6
let minimal_frame_size_allowed = 0x4000

let default =
  {
    header_table_size = 0x1000;
    enable_push = true;
    max_concurrent_streams = Int32.max_int;
    initial_window_size = Window_size.default_initial;
    max_frame_size = minimal_frame_size_allowed;
    max_header_list_size = None;
  }

type setting =
  | HeaderTableSize of int
  | EnablePush of int
  | MaxConcurrentStreams of int32
  | InitialWindowSize of int32
  | MaxFrameSize of int
  | MaxHeaderListSize of int

let serialize_key = function
  | HeaderTableSize _ -> 0x1
  | EnablePush _ -> 0x2
  | MaxConcurrentStreams _ -> 0x3
  | InitialWindowSize _ -> 0x4
  | MaxFrameSize _ -> 0x5
  | MaxHeaderListSize _ -> 0x6

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

(*
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
*)

(*
let write_settings_payload t settings_list =
  let open Faraday in
  List.iter
    (fun setting ->
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
*)
