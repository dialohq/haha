module Error_code = Error_code

module Error : sig
  type connection_error =
    | ProtocolViolation of (Error_code.t * string)
    | PeerError of (Error_code.t * string)
    | Exn of exn
        (** The type of connection error. Caused by a valiation of the protocol
            from the other side of connection, or an exception. *)
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
  type reader_payload =
    [ `Data of Cstruct.t | `End of Cstruct.t option * Header.t list ]

  type 'context reader_result = {
    action : [ `Continue | `Reset ];
    context : 'context;
  }

  type 'context writer_payload =
    [ `Data of Cstruct.t list | `End of Cstruct.t list option * Header.t list ]

  type 'context writer_result = {
    payload : 'context writer_payload;
    on_flush : unit -> unit;
    context : 'context;
  }

  type 'context reader = 'context -> reader_payload -> 'context reader_result
  type 'context writer = 'context -> window_size:int32 -> 'context writer_result
end

module Types : sig
  type 'context state =
    | InProgress of (unit -> 'context iteration)
    | End
    | Error of Error.connection_error

  and 'context iteration = {
    state : 'context state;
    closed_ctxs : (int32 * 'context) list;
  }
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

  type 'context interim_response
  (** The type representing an interim HEADERS response sent by the server.
      Those type of responses are informational and only informational (1xx)
      status codes are allowed for them. State of the associated stream is not
      affected.

      This type of response MAY be followed by multiple further interim
      responses and/or a single [final_response]. *)

  type 'context t =
    [ `Interim of 'context interim_response | `Final of 'context final_response ]
  (** The type representing all types of responses, meaning [final_response] or
      [interim_response]. *)

  type 'context handler =
    'context -> 'context t -> 'context reader option * 'context

  type 'context response_writer = unit -> 'context t
  (** The type of the callback function for writing response [t]. *)

  val status : 'context t -> Status.t
  val headers : 'context t -> Header.t list
  val create : Status.t -> Header.t list -> 'context final_response

  val create_interim :
    Status.informational -> Header.t list -> 'context interim_response

  val create_with_streaming :
    body_writer:'context writer ->
    Status.t ->
    Header.t list ->
    'context final_response
end

module Request : sig
  type 'context t
  type 'context request_writer = unit -> 'context t option

  val path : 'context t -> string
  val meth : 'context t -> Method.t
  val scheme : 'context t -> string
  val authority : 'context t -> string option
  val headers : 'context t -> Header.t list

  val create :
    ?authority:string ->
    ?scheme:string ->
    context:'context ->
    response_handler:'context Response.handler ->
    error_handler:('context -> Error_code.t -> 'context) ->
    headers:Header.t list ->
    Method.t ->
    string ->
    'context t

  val create_with_streaming :
    ?authority:string ->
    ?scheme:string ->
    body_writer:'context Body.writer ->
    context:'context ->
    response_handler:'context Response.handler ->
    error_handler:('context -> Error_code.t -> 'context) ->
    headers:Header.t list ->
    Method.t ->
    string ->
    'context t
end

module Reqd : sig
  type 'context handler_result = {
    on_data : 'context Body.reader;
    response_writer : 'context Response.response_writer;
    error_handler : 'context -> Error_code.t -> 'context;
    initial_context : 'context;
  }

  type t
  type 'context handler = t -> 'context handler_result

  val path : t -> string
  val meth : t -> Method.t
  val scheme : t -> string
  val authority : t -> string option
  val headers : t -> Header.t list
end

module Server : sig
  val connection_handler :
    'context.
    ?config:Settings.t ->
    ?goaway_writer:(unit -> unit) ->
    error_handler:(Error.connection_error -> unit) ->
    'context Reqd.handler ->
    [> `Flow | `R | `W ] Eio.Resource.t ->
    Eio.Net.Sockaddr.stream ->
    unit
end

(* TODO: shouldn't be exposed in whole *)
module Settings = Settings

module Client : sig
  type 'context iteration = 'context Types.iteration

  val connect :
    'context.
    ?config:Settings.t ->
    request_writer:'context Request.request_writer ->
    [> `Flow | `R | `W ] Eio.Resource.t ->
    'context iteration
end
