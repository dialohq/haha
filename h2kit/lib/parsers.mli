module type ReaderType = sig
  type 'a t

  val uint8 : int t
  val string : string -> unit t
  val return : 'a -> 'a t
  val skip : int -> unit t
  val ( <* ) : 'a t -> 'b t -> 'a t
  val ( *> ) : 'a t -> 'b t -> 'b t

  module BE : sig
    val uint16 : int t
    val uint32 : int32 t
  end

  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val map : ('a -> 'b) -> 'a t -> 'b t
  val pair : 'a t -> 'b t -> ('a * 'b) t

  val unsafe_take_bigarray :
    int ->
    (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t t
end

module type S = sig
  type 'a t

  val parse_frame : (Frame.t, Error.t) result t
  (** Parser for HTTP/2 frames *)

  val connection_preface : unit t
  (** Parser for magic string of the client's connection preface *)
end

module Make (Reader : ReaderType) : S with type 'a t = 'a Reader.t
