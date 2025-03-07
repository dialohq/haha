let connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

module FrameType = struct
  type t =
    (* From RFC7540§6.1:
     *   DATA frames (type=0x0) convey arbitrary, variable-length sequences
     *   of octets associated with a stream. *)
    | Data
    (* From RFC7540§6.2:
     *   The HEADERS frame (type=0x1) is used to open a stream (Section 5.1),
     *   and additionally carries a header block fragment. *)
    | Headers
    (* From RFC7540§6.3:
     *   The PRIORITY frame (type=0x2) specifies the sender-advised priority
     *   of a stream (Section 5.3). *)
    | Priority
    (* From RFC7540§6.4:
     *   The RST_STREAM frame (type=0x3) allows for immediate termination of
     *   a stream. *)
    | RSTStream
    (* From RFC7540§6.5:
     *   The SETTINGS frame (type=0x4) conveys configuration parameters that
     *   affect how endpoints communicate, such as preferences and
     *   constraints on peer behavior. *)
    | Settings
    (* From RFC7540§6.6:
     *   The PUSH_PROMISE frame (type=0x5) is used to notify the peer
     *   endpoint in advance of streams the sender intends to initiate. *)
    | PushPromise
    (* From RFC7540§6.7:
     *   The PING frame (type=0x6) is a mechanism for measuring a minimal
     *   round-trip time from the sender, as well as determining whether an
     *   idle connection is still functional. *)
    | Ping
    (* From RFC7540§6.8:
     *   The GOAWAY frame (type=0x7) is used to initiate shutdown of a
     *   connection or to signal serious error conditions. *)
    | GoAway
    (* From RFC7540§6.9:
     *   The WINDOW_UPDATE frame (type=0x8) is used to implement flow
     *   control; [...]. *)
    | WindowUpdate
    (* From RFC7540§6.10:
     *   The CONTINUATION frame (type=0x9) is used to continue a sequence of
     *   header block fragments (Section 4.3). *)
    | Continuation
    (* From RFC7540§5.1:
     *   Frames of unknown types are ignored. *)
    | Unknown of int

  let serialize = function
    | Data -> 0
    | Headers -> 1
    | Priority -> 2
    | RSTStream -> 3
    | Settings -> 4
    | PushPromise -> 5
    | Ping -> 6
    | GoAway -> 7
    | WindowUpdate -> 8
    | Continuation -> 9
    | Unknown x -> x

  let parse = function
    | 0 -> Data
    | 1 -> Headers
    | 2 -> Priority
    | 3 -> RSTStream
    | 4 -> Settings
    | 5 -> PushPromise
    | 6 -> Ping
    | 7 -> GoAway
    | 8 -> WindowUpdate
    | 9 -> Continuation
    | x -> Unknown x
end

(* From RFC7540§4.1:
 *   The fields of the frame header are defined as:
 *
 *     Length: The length of the frame payload expressed as an unsigned 24-bit
 *             integer. [...]
 *
 *     Type: The 8-bit type of the frame. [...]
 *
 *     Flags: An 8-bit field reserved for boolean flags specific to the frame
 *            type. [...]
 *
 *     Stream Identifier: A stream identifier (see Section 5.1.1) expressed as
 *                        an unsigned 31-bit integer. [...] *)
type frame_header = {
  payload_length : int;
  flags : Flags.t;
  stream_id : Stream_identifier.t;
  frame_type : FrameType.t;
}

(* From RFC7540§4.1:
 *   The structure and content of the frame payload is dependent entirely on
 *   the frame type. *)
type frame_payload =
  (* From RFC7540§6.1:
   *   The DATA frame contains the following fields:
   *
   *   [...]
   *
   *   Data: Application data. The amount of data is the remainder of the
   *         frame payload after subtracting the length of the other fields
   *         that are present. *)
  | Data of Bigstringaf.t
  (* From RFC7540§6.2:
   *   The HEADERS frame payload has the following fields:
   *
   *    E: A single-bit flag indicating that the stream dependency is
   *       exclusive (see Section 5.3). [...]
   *
   *    Stream Dependency: A 31-bit stream identifier for the stream that
   *                       this stream depends on (see Section 5.3). [...]
   *
   *    Weight: An unsigned 8-bit integer representing a priority weight for
   *            the stream (see Section 5.3). [...] This field is only
   *            present if the PRIORITY flag is set.
   *
   *    Header Block Fragment: A header block fragment (Section 4.3). *)
  | Headers of Priority.t * Bigstringaf.t
  (* From RFC7540§6.3:
   *   The payload of a PRIORITY frame contains the following fields:
   *
   *   E: A single-bit flag indicating that the stream dependency is
   *      exclusive (see Section 5.3).
   *
   *   Stream Dependency: A 31-bit stream identifier for the stream that this
   *                      stream depends on (see Section 5.3).
   *
   *   Weight: An unsigned 8-bit integer representing a priority weight for
   *           the stream (see Section 5.3). [...] *)
  | Priority of Priority.t
  (* From RFC7540§6.4:
   *   The RST_STREAM frame contains a single unsigned, 32-bit integer
   *   identifying the error code (Section 7). [...] *)
  | RSTStream of Error_code.t
  (* From RFC7540§6.5:
   *   The payload of a SETTINGS frame consists of zero or more parameters,
   *   each consisting of an unsigned 16-bit setting identifier and an
   *   unsigned 32-bit value. *)
  | Settings of Settings.settings_list
  (* From RFC7540§6.6:
   *   The PUSH_PROMISE frame includes the unsigned 31-bit identifier of the
   *   stream the endpoint plans to create along with a set of headers that
   *   provide additional context for the stream. *)
  | PushPromise of Stream_identifier.t * Bigstringaf.t
  (* From RFC7540§6.7:
   *   In addition to the frame header, PING frames MUST contain 8 octets of
   *   opaque data in the payload. A sender can include any value it chooses
   *   and use those octets in any fashion. *)
  | Ping of Bigstringaf.t
  (* From RFC7540§6.8:
   *   The last stream identifier in the GOAWAY frame contains the
   *   highest-numbered stream identifier for which the sender of the GOAWAY
   *   frame might have taken some action on or might yet take action on.
   *
   *   [...] The GOAWAY frame also contains a 32-bit error code (Section 7)
   *   that contains the reason for closing the connection.
   *
   *   [...] Endpoints MAY append opaque data to the payload of any GOAWAY
   *   frame. *)
  | GoAway of Stream_identifier.t * Error_code.t * Bigstringaf.t
  (* From RFC7540§6.9:
   *   The payload of a WINDOW_UPDATE frame is one reserved bit plus an
   *   unsigned 31-bit integer indicating the number of octets that the
   *   sender can transmit in addition to the existing flow-control
   *   window. *)
  | WindowUpdate of Settings.WindowSize.t
  (* From RFC7540§6.10:
   *   The CONTINUATION frame payload contains a header block fragment
   *   (Section 4.3). *)
  | Continuation of Bigstringaf.t
  | Unknown of int * Bigstringaf.t

(* From RFC7540§4.1:
 *   All frames begin with a fixed 9-octet header followed by a variable-length
 *   payload. *)
type t = { frame_header : frame_header; frame_payload : frame_payload }

let validate_frame_headers
    ({ frame_type; payload_length; flags; stream_id } : frame_header) :
    (unit, Error.t) result =
  let open Error_code in
  match frame_type with
  | Settings ->
      if not (Stream_identifier.is_connection stream_id) then
        Error.connection_error ProtocolError
          "SETTINGS must be associated with stream id 0x0"
      else if payload_length mod 6 <> 0 then
        Error.connection_error FrameSizeError
          "SETTINGS payload size must be a multiple of 6"
      else if Flags.test_ack flags && payload_length <> 0 then
        Error.connection_error FrameSizeError "SETTINGS with ACK must be empty"
      else Ok ()
  | Ping ->
      if not (Stream_identifier.is_connection stream_id) then
        Error.connection_error ProtocolError
          "PING must be associated with stream id 0x0"
      else if payload_length <> 8 then
        Error.connection_error FrameSizeError
          "PING payload must be 8 octets in length"
      else Ok ()
  | Headers ->
      if Stream_identifier.is_connection stream_id then
        Error.connection_error ProtocolError
          "HEADERS must be associated with a stream"
      else if Stream_identifier.is_server stream_id then
        Error.connection_error ProtocolError
          "HEADERS must have a odd-numbered stream identifier"
      else Ok ()
  | Data ->
      if Stream_identifier.is_connection stream_id then
        Error.connection_error ProtocolError
          "DATA frames must be associated with a stream"
      else Ok ()
  | PushPromise ->
      if Stream_identifier.is_connection stream_id then
        Error.connection_error ProtocolError
          "PUSH_PROMISE must be associated with a stream"
      else Ok ()
  | GoAway ->
      if not (Stream_identifier.is_connection stream_id) then
        Error.connection_error ProtocolError
          "GOAWAY must be associated with stream id 0x0"
      else Ok ()
  | RSTStream ->
      if Stream_identifier.is_connection stream_id then
        Error.connection_error ProtocolError
          "RST_STREAM must be associated with a stream"
      else if payload_length <> 4 then
        Error.connection_error FrameSizeError
          "RST_STREAM payload must be 4 octets in length"
      else Ok ()
  | _ -> failwith "validation not implemented"
