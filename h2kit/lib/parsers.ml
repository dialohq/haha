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
  val connection_preface : unit t
end

module Make (Reader : ReaderType) : S with type 'a t = 'a Reader.t = struct
  type 'a t = 'a Reader.t

  open Reader

  let ( >>| ) x y = map y x
  let ( >>= ) = bind
  let ( let+ ) = ( >>| )
  let ( let* ) = ( >>= )
  let ( and+ ) = pair
  let connection_error code msg = Error (Error.conn_prot_err code msg)
  let stream_error code id = Error (Error.stream_prot_err id code)
  let parse_uint24 o1 o2 o3 = (o1 lsl 16) lor (o2 lsl 8) lor o3

  let frame_length =
    let+ v1 = uint8 and+ v2 = uint8 and+ v3 = uint8 in
    parse_uint24 v1 v2 v3

  let frame_type = uint8 >>| Frame.FrameType.of_int
  let flags = uint8 >>| Flags.of_int

  let stream_identifier =
    BE.uint32 >>| fun n -> Int32.(logand n (sub (shift_left 1l 31) 1l))

  let parse_frame_header =
    let+ payload_length = frame_length
    and+ frame_type = frame_type
    and+ flags = flags
    and+ stream_id = stream_identifier in
    { Frame.flags; payload_length; stream_id; frame_type }

  let parse_padded_payload { Frame.payload_length; flags; _ } parser =
    if Flags.test_padded flags then
      uint8 >>= fun pad_length ->
      if pad_length >= payload_length then
        skip (payload_length - 1) >>| fun () ->
        connection_error ProtocolError "Padding size exceeds payload size"
      else
        let relevant_length = payload_length - 1 - pad_length in
        parser relevant_length <* skip pad_length
    else parser payload_length

  let parse_data_frame ({ Frame.payload_length; _ } as frame_header) =
    match Frame.validate_header frame_header with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let parse_data length =
          unsafe_take_bigarray length >>| fun bs ->
          Ok (Frame.Data (Cstruct.of_bigarray bs))
        in
        parse_padded_payload frame_header parse_data

  let parse_priority =
    let+ _stream_dependency = BE.uint32 and+ _weight = uint8 in
    ()

  let parse_headers_frame frame_header =
    let ({ Frame.payload_length; flags; _ } as headers) = frame_header in
    let priority = Flags.test_priority flags in
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let parse_headers length =
          let+ bs =
            if priority then skip 5 *> unsafe_take_bigarray (length - 5)
            else unsafe_take_bigarray length
          in
          Ok (Frame.Headers bs)
        in
        parse_padded_payload frame_header parse_headers

  let parse_priority_frame ({ Frame.payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ -> parse_priority >>| fun () -> Ok Frame.Priority

  let parse_error_code = BE.uint32 >>| Error_code.parse

  let parse_rst_stream_frame ({ Frame.payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        parse_error_code >>| fun error_code -> Ok (Frame.RSTStream error_code)

  let parse_settings_payload num_settings =
    let open Settings in
    let rec parse_inner acc remaining =
      if remaining <= 0 then return (List.rev acc)
      else
        (let+ k = BE.uint16 and+ v = BE.uint32 in
         match k with
         | 0x1 -> HeaderTableSize (Int32.to_int v) :: acc
         | 0x2 -> EnablePush (Int32.to_int v) :: acc
         | 0x3 -> MaxConcurrentStreams v :: acc
         | 0x4 -> InitialWindowSize v :: acc
         | 0x5 -> MaxFrameSize (Int32.to_int v) :: acc
         | 0x6 -> MaxHeaderListSize (Int32.to_int v) :: acc
         | _ -> acc)
        >>= fun acc' -> parse_inner acc' (remaining - 1)
    in
    parse_inner [] num_settings

  let parse_settings_frame ({ Frame.payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let num_settings = payload_length / Settings.octets_per_setting in
        parse_settings_payload num_settings >>| fun xs -> Ok (Frame.Settings xs)

  let parse_push_promise_frame frame_header =
    let { Frame.payload_length; _ } = frame_header in
    match Frame.validate_header frame_header with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let parse_push_promise length =
          let+ promised_stream_id = stream_identifier
          and+ fragment = unsafe_take_bigarray (length - 4) in
          if Stream_identifier.is_connection promised_stream_id then
            connection_error ProtocolError "PUSH must not promise stream id 0x0"
          else if Stream_identifier.is_client promised_stream_id then
            connection_error ProtocolError
              "PUSH must be associated with an even-numbered stream id"
          else Ok Frame.(PushPromise (promised_stream_id, fragment))
        in
        parse_padded_payload frame_header parse_push_promise

  let parse_ping_frame ({ Frame.payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        unsafe_take_bigarray payload_length >>| fun bs ->
        Ok (Frame.Ping (Cstruct.of_bigarray bs))

  let parse_go_away_frame ({ Frame.payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let+ last_stream_id = stream_identifier
        and+ err = parse_error_code
        and+ debug_data = unsafe_take_bigarray (payload_length - 8) in
        Ok (Frame.GoAway (last_stream_id, err, debug_data))

  let[@inline] clear_bit_int32 x i =
    let open Int32 in
    logand x (lognot (shift_left 1l i))

  let parse_window_update_frame
      ({ Frame.stream_id; payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let+ uint = BE.uint32 in
        let window_size_increment = clear_bit_int32 uint 31 in
        if Int32.equal window_size_increment 0l then
          if Stream_identifier.is_connection stream_id then
            connection_error ProtocolError "Window update must not be 0"
          else stream_error ProtocolError stream_id
        else Ok (Frame.WindowUpdate window_size_increment)

  let parse_continuation_frame ({ Frame.payload_length; _ } as headers) =
    match Frame.validate_header headers with
    | Error _ as err -> skip payload_length >>| fun () -> err
    | Ok _ ->
        let+ block_fragment = unsafe_take_bigarray payload_length in
        Ok (Frame.Continuation block_fragment)

  let parse_unknown_frame typ { Frame.payload_length; _ } =
    let+ bigstring = unsafe_take_bigarray payload_length in
    Ok (Frame.Unknown (typ, bigstring))

  let parse_frame_payload ({ Frame.frame_type; _ } as frame_header) =
    match frame_type with
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
    | Unknown typ -> parse_unknown_frame typ frame_header

  let parse_frame =
    let* frame_header = parse_frame_header in
    parse_frame_payload frame_header >>| function
    | Ok frame_payload -> Ok { Frame.frame_header; frame_payload }
    | Error e -> Error e

  let connection_preface = string Frame.connection_preface
end
