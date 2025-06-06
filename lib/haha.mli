module Error_code = Error_code

module Error : sig
  type connection_error =
    | ProtocolViolation of (Error_code.t * string)
    | PeerError of (Error_code.t * string)
    | Exn of exn
        (** The type of connection error. Caused by a valiation of the protocol
            from the other side of connection, or an exception. *)

  type stream_error = int32 * Error_code.t
  type t = ConnectionError of connection_error | StreamError of stream_error
end

module Header : sig
  type t = { name : string; value : string }
  (** The type of header *)

  val of_list : (string * string) list -> t list
  (** [of_list assoc] is list of header fields defined by a association list
      [assoc]. *)

  val to_list : t list -> (string * string) list
  (** [to_list l] is a association list of header fields contained in the list
      of headers [l]. *)

  val find_opt : string -> t list -> string option
  (** [find_opt name l] returns the first header from list of headers [l] with
      name [name], or [None] if no header name is present. *)
end

module Body : sig
  type reader_payload = [ `Data of Cstruct.t | `End of Header.t list ]

  type 'context writer_payload =
    [ `Data of Cstruct.t list | `End of Cstruct.t list option * Header.t list ]

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

module Method = Method
module Status = Status

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
  val headers : 'context t -> Header.t list
  val create : Status.t -> Header.t list -> 'context final_response
  val create_interim : Status.informational -> Header.t list -> interim_response

  val create_with_streaming :
    body_writer:'context writer ->
    Status.t ->
    Header.t list ->
    'context final_response
end

module Request : sig
  type t
  type request_writer = unit -> t option

  val path : t -> string
  val meth : t -> Method.t
  val scheme : t -> string
  val authority : t -> string option
  val headers : t -> Header.t list

  val create :
    ?authority:string ->
    ?scheme:string ->
    ?on_close:('context -> unit) ->
    context:'context ->
    response_handler:'context Response.handler ->
    error_handler:('context -> Error.t -> 'context) ->
    headers:Header.t list ->
    Method.t ->
    string ->
    t

  val create_with_streaming :
    ?authority:string ->
    ?scheme:string ->
    ?on_close:('context -> unit) ->
    context:'context ->
    body_writer:'context Body.writer ->
    response_handler:'context Response.handler ->
    error_handler:('context -> Error.t -> 'context) ->
    headers:Header.t list ->
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
  val headers : t -> Header.t list

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

(* TODO: shouldn't be exposed in whole *)
module Settings = Settings

module Client : sig
  type iter_input = Shutdown | Request of Request.t
  type iteration = iter_input Types.iteration

  val connect :
    'context.
    ?config:Settings.t -> [> `Flow | `R | `W ] Eio.Resource.t -> iteration
end
