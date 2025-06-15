open Faraday

type frame_info

val create_frame_info :
  ?flags:Flags.t -> ?padding_length:int -> int32 -> frame_info

val write_connection_preface : t -> unit
(** Serializer for magic string of client's connection preface *)

val write_data_frame : t -> Cstruct.t list -> frame_info -> unit
(** Serializer for DATA frame *)

val write_headers_frame :
  t -> Hpack.Encoder.t -> Headers.t -> frame_info -> unit
(** Serializer for HEADERS frame *)

val write_rst_stream_frame : t -> Stream_identifier.t -> Error_code.t -> unit
(** Serializer for RST_STREAM frame *)

val write_settings_frame : t -> Settings.setting list -> frame_info -> unit
(** Serializer for SETTINGS frame *)

val write_ping_frame : t -> Cstruct.t -> frame_info -> unit
(** Serializer for PING frame *)

val write_goaway_frame :
  ?debug_data:Cstruct.t -> t -> Stream_identifier.t -> Error_code.t -> unit
(** Serializer for GOAWAY frame *)

val write_window_update_frame : t -> Stream_identifier.t -> int32 -> unit
(** Serializer for WINDOW_UPDATE frame *)
