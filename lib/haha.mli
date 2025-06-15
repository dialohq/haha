module Error_code = H2kit.Error_code

module Error : sig
  type connection_error = H2kit.Error.connection_error
  type stream_error = H2kit.Error.stream_error
  type t = H2kit.Error.t
end

module Headers : sig
  type t
  (** Type representing a set of header fields *)

  val empty : t
  val of_list : (string * string) list -> t
  val to_list : t -> (string * string) list
  val iter : (string * string -> unit) -> t -> unit
  val find_opt : string -> t -> string option
  val length : t -> int
  val join : t list -> t
end

module Body : sig
  type reader_payload = [ `Data of Cstruct.t | `End of Headers.t ]

  type 'context writer_payload =
    [ `Data of Cstruct.t list | `End of Cstruct.t list option * Headers.t ]

  type 'context writer_result = {
    payload : 'context writer_payload;
    on_flush : unit -> unit;
    context : 'context;
  }

  type 'context reader = 'context -> reader_payload -> 'context
  type 'context writer = 'context -> 'context writer_result

  val ignore_reader : _ reader
end

module Types : sig
  type 'input state =
    | InProgress of ('input list -> 'input iteration)
    | End
    | Error of Error.connection_error

  and 'input iteration = { state : 'input state; active_streams : int }
end

module Method = H2kit.Method
module Status = H2kit.Status

module Response : sig
  open Body

  type 'context final_response
  (** The type representing the final HEADERS resposne sent by the server,
      closing the stream with the END_STREAM flag from the server side. This
      will cause the associated stream to transition to either half_closed or
      closed state.

      No further responses will be send the this stream after this type of
      response. *)

  type interim_response
  (** The type representing an interim HEADERS response sent by the server.
      Those type of responses are informational and only informational (1xx)
      status codes are allowed for them. State of the associated stream is not
      affected.

      This type of response MAY be followed by multiple further interim
      responses and/or a single [final_response]. *)

  type 'context t =
    [ `Interim of interim_response | `Final of 'context final_response ]
  (** The type representing all types of responses, meaning [final_response] or
      [interim_response]. *)

  type 'context handler =
    'context -> 'context t -> 'context reader option * 'context

  type 'context response_writer = unit -> 'context t
  (** The type of the callback function for writing response [t]. *)

  val status : 'context t -> Status.t
  val headers : 'context t -> Headers.t
  val create : ?headers:Headers.t -> Status.t -> 'context final_response

  val create_interim :
    ?headers:Headers.t -> Status.informational -> interim_response

  val create_with_streaming :
    ?headers:Headers.t ->
    body_writer:'context writer ->
    Status.t ->
    'context final_response
end

module Request : sig
  type t
  type request_writer = unit -> t option

  val path : t -> string
  val meth : t -> Method.t
  val scheme : t -> string
  val authority : t -> string option
  val headers : t -> Headers.t

  val create :
    ?authority:string ->
    ?scheme:string ->
    ?on_close:('context -> unit) ->
    ?headers:Headers.t ->
    context:'context ->
    response_handler:'context Response.handler ->
    error_handler:('context -> Error.t -> 'context) ->
    Method.t ->
    string ->
    t

  val create_with_streaming :
    ?authority:string ->
    ?scheme:string ->
    ?on_close:('context -> unit) ->
    ?headers:Headers.t ->
    context:'context ->
    body_writer:'context Body.writer ->
    response_handler:'context Response.handler ->
    error_handler:('context -> Error.t -> 'context) ->
    Method.t ->
    string ->
    t
end

module Reqd : sig
  type handler_result
  type t
  type handler = t -> handler_result

  val path : t -> string
  val meth : t -> Method.t
  val scheme : t -> string
  val authority : t -> string option
  val headers : t -> Headers.t

  val handle :
    ?on_close:('a -> unit) ->
    context:'a ->
    response_writer:'a Response.response_writer ->
    body_reader:'a Body.reader ->
    error_handler:('a -> Error.t -> 'a) ->
    unit ->
    handler_result

  val pp_hum : Format.formatter -> t -> unit
end

module Settings : sig
  type t = {
    header_table_size : int;
    enable_push : bool;
    max_concurrent_streams : int32;
    initial_window_size : int32;
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
end

module Server : sig
  val connection_handler :
    'context.
    ?config:Settings.t ->
    ?goaway_writer:(unit -> unit) ->
    error_handler:(Error.connection_error -> unit) ->
    Reqd.handler ->
    [> `Flow | `R | `W ] Eio.Resource.t ->
    Eio.Net.Sockaddr.stream ->
    unit
end

module Client : sig
  type iter_input = Shutdown | Request of Request.t
  type iteration = iter_input Types.iteration

  val connect :
    'context.
    ?config:Settings.t -> [> `Flow | `R | `W ] Eio.Resource.t -> iteration
end
