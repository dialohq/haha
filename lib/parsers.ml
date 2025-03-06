open Angstrom

let default_frame_header =
  {
    Frame.payload_length = 0;
    flags = Flags.default_flags;
    stream_id = -1l;
    frame_type = Unknown (-1);
  }

type parse_context = {
  mutable remaining_bytes_to_skip : int;
  mutable did_report_stream_error : bool;
  (* TODO: This should change as new settings frames arrive, but we don't yet
   * resize the read buffer. *)
  max_frame_size : int;
}

let create_parse_context max_frame_size =
  {
    remaining_bytes_to_skip = 0;
    did_report_stream_error = false;
    max_frame_size;
  }

let connection_error error_code msg =
  Error Error.(ConnectionError (error_code, msg))

let stream_error error_code stream_id =
  Error Error.(StreamError (stream_id, error_code))

let parse_uint24 o1 o2 o3 = (o1 lsl 16) lor (o2 lsl 8) lor o3

let frame_length =
  (* From RFC7540§4.1:
   *   Length: The length of the frame payload expressed as an unsigned 24-bit
   *   integer. *)
  lift3 parse_uint24 any_uint8 any_uint8 any_uint8

let frame_type =
  (* From RFC7540§4.1:
   *   Type: The 8-bit type of the frame. The frame type determines the format
   *   and semantics of the frame. Implementations MUST ignore and discard any
   *   frame that has a type that is unknown. *)
  lift Frame.FrameType.parse any_uint8

let flags =
  (* From RFC7540§4.1:
   *   Flags: An 8-bit field reserved for boolean flags specific to the frame
   *   type. *)
  any_uint8

let parse_stream_identifier n =
  (* From RFC7540§4.1:
   *   Stream Identifier: A stream identifier (see Section 5.1.1) expressed as
   *   an unsigned 31-bit integer. The value 0x0 is reserved for frames that
   *   are associated with the connection as a whole as opposed to an
   *   individual stream. *)
  Int32.(logand n (sub (shift_left 1l 31) 1l))

let stream_identifier = lift parse_stream_identifier BE.any_int32

let parse_frame_header =
  lift4
    (fun payload_length frame_type flags stream_id ->
      { Frame.flags; payload_length; stream_id; frame_type })
    frame_length frame_type flags stream_identifier
  <?> "frame_header"
  (* The parser commits after parsing the frame header so that the entire
   * underlying buffer can be used to store the payload length. This matters
   * because the size of the buffer that gets allocated is the maximum frame
   * payload negotiated by the HTTP/2 settings synchronization. The 9 octets
   * that make up the frame header are, therefore, very important in order for
   * h2 not to return a FRAME_SIZE_ERROR. *)
  <* commit

let parse_padded_payload { Frame.payload_length; flags; _ } parser =
  if Flags.test_padded flags then
    any_uint8 >>= fun pad_length ->
    (* From RFC7540§6.1:
     *   Pad Length: An 8-bit field containing the length of the frame
     *   padding in units of octets.
     *
     *   Data: Application data. The amount of data is the remainder of the
     *   frame payload after subtracting the length of the other fields that
     *   are present.
     *
     *   Padding: Padding octets that contain no application semantic
     *   value. *)
    if pad_length >= payload_length then
      (* From RFC7540§6.1:
       *   If the length of the padding is the length of the frame payload or
       *   greater, the recipient MUST treat this as a connection error
       *   (Section 5.4.1) of type PROTOCOL_ERROR. *)
      advance (payload_length - 1) >>| fun () ->
      connection_error ProtocolError "Padding size exceeds payload size"
    else
      (* Subtract the octet that contains the length of padding, and the
       * padding octets. *)
      let relevant_length = payload_length - 1 - pad_length in
      parser relevant_length <* advance pad_length
  else parser payload_length

let parse_data_frame ({ Frame.stream_id; payload_length; _ } as frame_header) =
  if Stream_identifier.is_connection stream_id then
    (* From RFC7540§6.1:
     *   DATA frames MUST be associated with a stream. If a DATA frame is
     *   received whose stream identifier field is 0x0, the recipient MUST
     *   respond with a connection error (Section 5.4.1) of type
     *   PROTOCOL_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error ProtocolError
      "Data frames must be associated with a stream"
  else
    let parse_data length =
      lift (fun bs -> Ok (Frame.Data bs)) (take_bigstring length)
    in
    parse_padded_payload frame_header parse_data

let parse_priority =
  lift2
    (fun stream_dependency weight ->
      let e = Priority.test_exclusive stream_dependency in
      {
        Priority.exclusive =
          e
          (* From RFC7540§6.3:
           *   An unsigned 8-bit integer representing a priority weight for the
           *   stream (see Section 5.3). Add one to the value to obtain a
           *   weight between 1 and 256. *);
        weight = weight + 1;
        stream_dependency = parse_stream_identifier stream_dependency;
      })
    BE.any_int32 any_uint8

let parse_headers_frame frame_header =
  let ({ Frame.flags; _ } as headers) = frame_header in
  match Frame.validate_frame_headers headers with
  | Error _ as err -> return err
  | Ok _ ->
      let parse_headers length =
        if Flags.test_priority flags then
          lift2
            (fun priority headers -> Ok (Frame.Headers (priority, headers)))
            parse_priority
            (* See RFC7540§6.3:
             *   Stream Dependency (4 octets) + Weight (1 octet). *)
            (take_bigstring (length - 5))
        else
          lift
            (fun headers_block ->
              Ok (Frame.Headers (Priority.default_priority, headers_block)))
            (take_bigstring length)
      in
      parse_padded_payload frame_header parse_headers

let parse_priority_frame { Frame.payload_length; stream_id; _ } =
  if Stream_identifier.is_connection stream_id then
    (* From RFC7540§6.3:
     *   The PRIORITY frame always identifies a stream. If a PRIORITY frame is
     *   received with a stream identifier of 0x0, the recipient MUST respond
     *   with a connection error (Section 5.4.1) of type PROTOCOL_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error ProtocolError "PRIORITY must be associated with a stream"
  else if payload_length <> 5 then
    (* From RFC7540§6.3:
     *   A PRIORITY frame with a length other than 5 octets MUST be treated as
     *   a stream error (Section 5.4.2) of type FRAME_SIZE_ERROR. *)
    advance payload_length >>| fun () -> stream_error FrameSizeError stream_id
  else lift (fun priority -> Ok (Frame.Priority priority)) parse_priority

let parse_error_code = lift Error_code.parse BE.any_int32

let parse_rst_stream_frame { Frame.payload_length; stream_id; _ } =
  if Stream_identifier.is_connection stream_id then
    (* From RFC7540§6.4:
     *   RST_STREAM frames MUST be associated with a stream. If a RST_STREAM
     *   frame is received with a stream identifier of 0x0, the recipient MUST
     *   treat this as a connection error (Section 5.4.1) of type
     *   PROTOCOL_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error ProtocolError "RST_STREAM must be associated with a stream"
  else if payload_length <> 4 then
    (* From RFC7540§6.4:
     *   A RST_STREAM frame with a length other than 4 octets MUST be treated
     *   as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error FrameSizeError
      "RST_STREAM payload must be 4 octets in length"
  else lift (fun error_code -> Ok (Frame.RSTStream error_code)) parse_error_code

let parse_settings_payload num_settings =
  let open Angstrom in
  let open Settings in
  let rec parse_inner acc remaining =
    (* From RFC7540§6.5.3:
     *   The values in the SETTINGS frame MUST be processed in the order
     *   they appear, with no other frame processing between values. *)
    if remaining <= 0 then return (List.rev acc)
    else
      lift2
        (fun k (v : int32) ->
          match k with
          | 0x1 -> HeaderTableSize (Int32.to_int v) :: acc
          | 0x2 -> EnablePush (Int32.to_int v) :: acc
          | 0x3 -> MaxConcurrentStreams v :: acc
          | 0x4 -> InitialWindowSize v :: acc
          | 0x5 -> MaxFrameSize (Int32.to_int v) :: acc
          | 0x6 -> MaxHeaderListSize (Int32.to_int v) :: acc
          | _ ->
              (* Note: This ignores unknown settings.
               *
               * From RFC7540§6.5.3:
               *   Unsupported parameters MUST be ignored.
               *)
              acc)
        BE.any_uint16 BE.any_int32
      >>= fun acc' -> parse_inner acc' (remaining - 1)
  in
  parse_inner [] num_settings

let parse_settings_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_frame_headers headers with
  | Error _ as err -> return err
  | Ok _ ->
      let num_settings = payload_length / Settings.octets_per_setting in
      parse_settings_payload num_settings >>| fun xs -> Ok (Frame.Settings xs)

let parse_push_promise_frame frame_header =
  let { Frame.payload_length; stream_id; _ } = frame_header in
  if Stream_identifier.is_connection stream_id then
    (* From RFC7540§6.6:
     *   The stream identifier of a PUSH_PROMISE frame indicates the
     *   stream it is associated with. If the stream identifier field
     *   specifies the value 0x0, a recipient MUST respond with a
     *   connection error (Section 5.4.1) of type PROTOCOL_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error ProtocolError "PUSH must be associated with a stream"
  else
    let parse_push_promise length =
      lift2
        (fun promised_stream_id fragment ->
          if Stream_identifier.is_connection promised_stream_id then
            (* From RFC7540§6.6:
             *   A receiver MUST treat the receipt of a PUSH_PROMISE that
             *   promises an illegal stream identifier (Section 5.1.1) as a
             *   connection error (Section 5.4.1) of type PROTOCOL_ERROR. *)
            connection_error ProtocolError "PUSH must not promise stream id 0x0"
          else if Stream_identifier.is_client promised_stream_id then
            (* From RFC7540§6.6:
             *   A receiver MUST treat the receipt of a PUSH_PROMISE that
             *   promises an illegal stream identifier (Section 5.1.1) as a
             *   connection error (Section 5.4.1) of type PROTOCOL_ERROR.
             *
             * Note: An odd-numbered stream is an invalid stream identifier for
             * the server, and only the server can send PUSH_PROMISE frames:
             *
             * From RFC7540§8.2.1:
             *   PUSH_PROMISE frames MUST NOT be sent by the client. *)
            connection_error ProtocolError
              "PUSH must be associated with an even-numbered stream id"
          else Ok Frame.(PushPromise (promised_stream_id, fragment)))
        stream_identifier
        (* From RFC7540§6.6:
         *   The PUSH_PROMISE frame includes the unsigned 31-bit identifier of
         *   the stream the endpoint plans to create along with a set of
         *   headers that provide additional context for the stream. *)
        (take_bigstring (length - 4))
    in
    parse_padded_payload frame_header parse_push_promise

let parse_ping_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_frame_headers headers with
  | Error _ as err -> return err
  | Ok _ -> lift (fun bs -> Ok (Frame.Ping bs)) (take_bigstring payload_length)

let parse_go_away_frame { Frame.payload_length; stream_id; _ } =
  if not (Stream_identifier.is_connection stream_id) then
    (* From RFC7540§6.8:
     *   The GOAWAY frame applies to the connection, not a specific stream. An
     *   endpoint MUST treat a GOAWAY frame with a stream identifier other than
     *   0x0 as a connection error (Section 5.4.1) of type PROTOCOL_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error ProtocolError
      "GOAWAY must be associated with stream id 0x0"
  else
    lift3
      (fun last_stream_id err debug_data ->
        Ok (Frame.GoAway (last_stream_id, err, debug_data)))
      stream_identifier parse_error_code
      (take_bigstring (payload_length - 8))

let parse_window_update_frame { Frame.stream_id; payload_length; _ } =
  (* From RFC7540§6.9:
   *   A WINDOW_UPDATE frame with a length other than 4 octets MUST be treated
   *   as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR. *)
  if payload_length <> 4 then
    advance payload_length >>| fun () ->
    connection_error FrameSizeError
      "WINDOW_UPDATE payload must be 4 octets in length"
  else
    lift
      (fun uint ->
        (* From RFC7540§6.9:
         *   The frame payload of a WINDOW_UPDATE frame is one reserved bit
         *   plus an unsigned 31-bit integer indicating the number of octets
         *   that the sender can transmit in addition to the existing
         *   flow-control window. *)
        let window_size_increment = Util.clear_bit_int32 uint 31 in
        if Int32.equal window_size_increment 0l then
          if
            (* From RFC7540§6.9:
             * A receiver MUST treat the receipt of a WINDOW_UPDATE frame
             * with an flow-control window increment of 0 as a stream error
             * (Section 5.4.2) of type PROTOCOL_ERROR; errors on the
             * connection flow-control window MUST be treated as a connection
             * error (Section 5.4.1). *)
            Stream_identifier.is_connection stream_id
          then connection_error ProtocolError "Window update must not be 0"
          else stream_error ProtocolError stream_id
        else Ok (Frame.WindowUpdate window_size_increment))
      BE.any_int32

let parse_continuation_frame { Frame.payload_length; stream_id; _ } =
  if Stream_identifier.is_connection stream_id then
    (* From RFC7540§6.10:
     *   CONTINUATION frames MUST be associated with a stream. If a
     *   CONTINUATION frame is received whose stream identifier field is 0x0,
     *   the recipient MUST respond with a connection error (Section 5.4.1) of
     *   type PROTOCOL_ERROR. *)
    advance payload_length >>| fun () ->
    connection_error ProtocolError
      "CONTINUATION must be associated with a stream"
  else
    lift
      (fun block_fragment -> Ok (Frame.Continuation block_fragment))
      (take_bigstring payload_length)

let parse_unknown_frame typ { Frame.payload_length; _ } =
  lift
    (fun bigstring -> Ok (Frame.Unknown (typ, bigstring)))
    (take_bigstring payload_length)

let parse_frame_payload ({ Frame.frame_type; _ } as frame_header) =
  (match frame_type with
  | Frame.FrameType.Data -> parse_data_frame frame_header
  | Headers -> parse_headers_frame frame_header
  | Priority -> parse_priority_frame frame_header
  | RSTStream -> parse_rst_stream_frame frame_header
  | Settings -> parse_settings_frame frame_header
  | PushPromise -> parse_push_promise_frame frame_header
  | Ping -> parse_ping_frame frame_header
  | GoAway -> parse_go_away_frame frame_header
  | WindowUpdate -> parse_window_update_frame frame_header
  | Continuation -> parse_continuation_frame frame_header
  | Unknown typ -> parse_unknown_frame typ frame_header)
  <?> "frame_payload"

let parse_frame =
  parse_frame_header >>= fun frame_header ->
  lift
    (function
      | Ok frame_payload -> Ok { Frame.frame_header; frame_payload }
      | Error e -> Error e)
    (parse_frame_payload frame_header)

let connection_preface =
  string Frame.connection_preface <?> "connection preface"

let settings_preface =
  parse_frame >>| function
  | Ok ({ frame_payload = Frame.Settings settings_list; _ } as frame) ->
      Ok (frame, settings_list)
  | Ok _ ->
      Error
        (`Error
           Error.(
             ConnectionError
               ( ProtocolError,
                 "Invalid connection preface. Magic sequence should be \
                  followed by the settings frame." )))
  | Error e -> Error (`Error e)
