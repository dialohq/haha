module Server = Server
module Error = Error
module Error_code = Error_code

module Settings : sig
  type t = {
    header_table_size : int;
    enable_push : bool;
    max_concurrent_streams : int32;
    initial_window_size : int32;
    max_frame_size : int;
    max_header_list_size : int option;
  }

  val default : t
  val pp_hum : Format.formatter -> t -> unit
end
