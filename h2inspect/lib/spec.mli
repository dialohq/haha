open H2kit

exception Fail of string

type state
type 'a t = state -> 'a

val make_state : next_element:(unit -> Element.t) -> writer:Writer.t -> state
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
val many : 'a t -> 'a list t
val frame_header : Frame.frame_header t
val magic : unit t
val settings : Settings.setting list t
val settings_ack : unit t
val ping : Cstruct.t t
val window_update : int32 t
val goaway : (int32 * Error_code.t * Cstruct.t) t
val headers : Cstruct.t t
val rst_stream : (int32 * Error_code.t) t
val data : Cstruct.t t
val conn_error : Error_code.t -> unit t
val stream_error : int32 -> Error_code.t -> unit t
val eof : unit t

module Sets : sig
  val preface : unit t
  val conn_only : unit t
end

module I = Ignore
module S = Sets
