(** This module provides a set of serializers for crafting HTTP/2 frames.

    The serializers are designed to be modular and independent of the underlying
    writing mechanism. This is achieved through the {!Make} functor, which takes
    a module of type {!BufWriterType} as an argument. This {!BufWriterType}
    module is responsible for handling the actual writing of data to a buffer.

    This design allows you to choose your preferred buffered writing
    implementation. Two popular choices are
    {{:https://ocaml.org/p/faraday/0.8.2/doc/Faraday/index.html}Faraday} and
    {{:https://ocaml-multicore.github.io/eio/eio/Eio/Buf_write/index.html}Eio.Buf_write}.

    {2 Using with Faraday}

    The {{:https://ocaml.org/p/faraday/0.8.2/doc/Faraday/index.html}Faraday}
    library's main module is fully compatible with the {!BufWriterType}
    signature. You can directly pass it to the {!Make} functor:

    {[
      module FaradaySerializers = Serializers.Make (Faraday)
    ]}

    {2 Using with Eio}

    If you are working within the {{:https://github.com/ocaml-multicore/eio}Eio}
    ecosystem, you can use its
    {{:https://ocaml-multicore.github.io/eio/eio/Eio/Buf_write/index.html}Buf_write}
    module. As
    {{:https://ocaml-multicore.github.io/eio/eio/Eio/Buf_write/index.html}Eio.Buf_write}
    has a slightly different interface, you'll need to create a small wrapper
    module to adapt it to the {!BufWriterType} signature.

    Here is a wrapper for
    {{:https://ocaml-multicore.github.io/eio/eio/Eio/Buf_write/index.html}Eio.Buf_write}
    you can use:

    {[
      module Buf_write = struct
        include Buf_write

        let write_uint8 = uint8
        let write_string = string

        let schedule_bigstring t ?off ?len bs =
          let cs = Cstruct.of_bigarray bs ?off ?len in
          schedule_cstruct t cs

        module BE = struct
          include BE

          let write_uint32 = uint32
          let write_uint16 = uint16
        end
      end

      module EioSerializers = Serializers.Make (Buf_write)
    ]}

    This approach allows you to seamlessly integrate the HTTP/2 serializers with
    your Eio-based application. *)

(** The interface for a buffered writer that the serializers will use to output
    data. It abstracts the specifics of the underlying I/O mechanism, allowing
    the serializers to be generic. *)
module type BufWriterType = sig
  type t
  (** The abstract type for the buffered writer. *)

  val write_uint8 : t -> int -> unit
  (** [write_uint8 t i] copies the lower 8 bits of n into the serializer's
      internal buffer. *)

  val write_string : t -> ?off:int -> ?len:int -> string -> unit
  (** [write_string t ?off ?len str] copies [str] into the serializer's internal
      buffer. *)

  val schedule_bigstring : t -> ?off:int -> ?len:int -> Bigstringaf.t -> unit
  (** [schedule_bigstring t ?off ?len bigstring] schedules [bigstring] to be
      written the next time the serializer surfaces writes to the user.
      [bigstring] is not copied in this process and [bigstring] should only be
      modified after [t] has been flushed. *)

  module BE : sig
    val write_uint16 : t -> int -> unit
    (** [write_uint16 t n] copies the lower 16 bits of [n] into the serializer's
        internal buffer in big-endian byte order. *)

    val write_uint32 : t -> int32 -> unit
    (** [write_uint32 t n] copies [n] into the serializer's internal buffer in
        big-endian byte order. *)
  end
end

module type S = sig
  type t

  type frame_info = {
    flags : Flags.t;
    stream_id : Stream_identifier.t;
    padding_length : int;
  }

  val create_frame_info :
    ?flags:Flags.t -> ?padding_length:int -> int32 -> frame_info

  (** Module for writing individual parts of specific frames.

      Those are normally called for you internally in each frame's serializer,
      but can be useful as seprate functions for tests (e.g. when you want to
      write an invalid frame). *)
  module LowLevel : sig
    val write_frame_header : Frame.frame_header -> t -> unit
    (** Serializer for frame header *)

    val write_data_frame_payload : Cstruct.t list -> t -> unit
    (** Serializer for DATA frame payload *)

    val write_rst_stream_frame_payload : Error_code.t -> t -> unit
    (** Serializer for RST_STREAM frame payload *)

    val write_settings_frame_payload : Settings.setting list -> t -> unit
    (** Serializer for SETTINGS frame payload *)

    val write_goaway_frame_payload :
      ?debug_data:Cstruct.t -> int32 -> Error_code.t -> t -> unit
    (** Serializer for GOAWAY frame payload *)

    val write_window_update_frame_payload : int32 -> t -> unit
    (** Serializer for WINDOW_UPDATE frame payload *)
  end

  val write_connection_preface : t -> unit
  (** Serializer for magic string of client's connection preface *)

  val write_data_frame : Cstruct.t list -> frame_info -> t -> unit
  (** Serializer for DATA frame *)

  val write_headers_frame :
    Hpack.Encoder.t -> Headers.t -> frame_info -> t -> unit
  (** Serializer for HEADERS frame *)

  val write_rst_stream_frame : Stream_identifier.t -> Error_code.t -> t -> unit
  (** Serializer for RST_STREAM frame *)

  val write_settings_frame : Settings.setting list -> frame_info -> t -> unit
  (** Serializer for SETTINGS frame *)

  val write_ping_frame : Cstruct.t -> frame_info -> t -> unit
  (** Serializer for PING frame *)

  val write_goaway_frame :
    ?debug_data:Cstruct.t -> Stream_identifier.t -> Error_code.t -> t -> unit
  (** Serializer for GOAWAY frame *)

  val write_window_update_frame : Stream_identifier.t -> int32 -> t -> unit
  (** Serializer for WINDOW_UPDATE frame *)
end

(** The {!Make} functor takes a module [BufWriter] that conforms to the
    {!BufWriterType} signature and returns a new module of type {!S}. The
    resulting module provides a set of functions for serializing various HTTP/2
    frames. *)
module Make (BufWriter : BufWriterType) : S with type t = BufWriter.t
