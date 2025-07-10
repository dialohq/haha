open H2kit

type 'a t

val ( *> ) : _ t -> 'a t -> 'a t
val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t
val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
val ( >>| ) : 'a t -> ('a -> 'b) -> 'b t
val ( +> ) : (Writer.t -> unit) -> 'a t -> 'a t
val ( <+ ) : 'a t -> (Writer.t -> unit) -> 'a t
val ( ++ ) : (Writer.t -> unit) -> (Writer.t -> unit) -> Writer.t -> unit
val return : 'a -> 'a t
val fail : string -> _ t
val register_ignore : Ignore.t -> unit t
val reset_ignore : unit t
val frame_header : Frame.frame_header t
val magic : unit t
val settings : Settings.setting list t
val settings_ack : unit t
val ping : Cstruct.t t
val window_update : int32 t
val goaway : (int32 * Error_code.t * Cstruct.t) t
val headers : Cstruct.t t
val rst_stream : (int32 * Error_code.t) t
val conn_error : Error_code.t -> unit t
val stream_error : int32 -> Error_code.t -> unit t
val eof : unit t

module Sets : sig
  val preface : unit t
  val conn_only : unit t
end

module I = Ignore
module S = Sets

type test = {
  label : string;
  runner : unit t;
  description : (string, Format.formatter, unit, string) format4 option;
}

type test_group = {
  label : string;
  tests : test list;
  assume : Case.action list;
}

val run_groups :
  sw:Eio.Switch.t ->
  net:[> [ `Generic | `Unix ] Eio.Net.ty ] Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  int ->
  test_group list ->
  Case.case list
