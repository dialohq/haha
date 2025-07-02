open H2kit

type t

val ( >> ) : t -> t -> t
val ( *> ) : t -> t -> t
val ( <* ) : t -> t -> t

module Ignore : sig
  val reset : t
  val window_update : t
  val stream_frames : t
end

module Expect : sig
  val magic : t
  val settings : t
  val settings_ack : t
  val ping : t
  val window_update : t
  val goaway : t
  val headers : t
  val conn_error : Error_code.t -> t
  val eof : t
end

module Write : sig
  val settings : Settings.setting list -> t
  val settings_ack : t

  val custom_header_settings :
    ?flags:Flags.t -> ?len:int -> ?id:int32 -> unit -> t

  val unknown_setting : t
  val ping : t
  val custom_header_ping : ?flags:Flags.t -> ?len:int -> ?id:int32 -> unit -> t
  val goaway : Error_code.t -> t

  val custom_header_goaway :
    ?flags:Flags.t -> ?len:int -> ?id:int32 -> unit -> t

  val window_update : ?flags:Flags.t -> ?len:int -> ?id:int32 -> int32 -> t
  val unknown : t

  val headers :
    ?flags:Flags.t ->
    ?len:int ->
    ?id:int32 ->
    ?pad_len:int ->
    [ `Block of Cstruct.t | `List of (string * string) list ] ->
    t

  val rst_stream : ?flags:Flags.t -> ?len:int -> ?id:int32 -> Error_code.t -> t
end

module Sets : sig
  val preface : t
  val conn_only : t
end

module I = Ignore
module E = Expect
module W = Write
module S = Sets

type test = {
  label : string;
  runner : t;
  description : (string, Format.formatter, unit, string) format4 option;
}

type test_group = { label : string; tests : test list }

val run_groups :
  sw:Eio.Switch.t ->
  net:[> [ `Generic | `Unix ] Eio.Net.ty ] Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  test_group list ->
  unit
