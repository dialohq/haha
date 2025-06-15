type t = {
  header_table_size : int;
  enable_push : bool;
  max_concurrent_streams : int32;
  initial_window_size : Window_size.t;
  max_frame_size : int;
  max_header_list_size : int option;
}

val octets_per_setting : int
val minimal_frame_size_allowed : int
val default : t

type setting =
  | HeaderTableSize of int
  | EnablePush of int
  | MaxConcurrentStreams of int32
  | InitialWindowSize of int32
  | MaxFrameSize of int
  | MaxHeaderListSize of int

val serialize_key : setting -> int
val update_with_list : t -> setting list -> t
