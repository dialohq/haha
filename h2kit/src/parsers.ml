open Angstrom
module AU = Angstrom.Unbuffered

let connection_error code msg = Error (Error.conn_prot_err code msg)
let stream_error code id = Error (Error.stream_prot_err id code)
let parse_uint24 o1 o2 o3 = (o1 lsl 16) lor (o2 lsl 8) lor o3

let take_bigstring_unsafe n =
  Unsafe.take n (fun bs ~off ~len -> Bigstringaf.sub bs ~off ~len)

let frame_length = lift3 parse_uint24 any_uint8 any_uint8 any_uint8
let frame_type = any_uint8 >>| Frame.FrameType.of_int
let flags = any_uint8 >>| Flags.of_int

let stream_identifier =
  BE.any_int32 >>| fun n -> Int32.(logand n (sub (shift_left 1l 31) 1l))

let parse_frame_header =
  lift4
    (fun payload_length frame_type flags stream_id ->
      { Frame.flags; payload_length; stream_id; frame_type })
    frame_length frame_type flags stream_identifier
  <?> "frame_header" <* commit

let parse_padded_payload { Frame.payload_length; flags; _ } parser =
  if Flags.test_padded flags then
    any_uint8 >>= fun pad_length ->
    if pad_length >= payload_length then
      advance (payload_length - 1) >>| fun () ->
      connection_error ProtocolError "Padding size exceeds payload size"
    else
      let relevant_length = payload_length - 1 - pad_length in

      parser relevant_length <* advance pad_length
  else parser payload_length

let parse_data_frame ({ Frame.payload_length; _ } as frame_header) =
  match Frame.validate_header frame_header with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      let parse_data length =
        take_bigstring_unsafe length >>| fun bs ->
        Ok (Frame.Data (Cstruct.of_bigarray bs))
      in
      parse_padded_payload frame_header parse_data

let parse_priority =
  lift2 (fun _stream_dependency _weight -> ()) BE.any_int32 any_uint8

let parse_headers_frame frame_header =
  let ({ Frame.payload_length; flags; _ } as headers) = frame_header in
  let priority = Flags.test_priority flags in
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      let parse_headers length =
        lift
          (fun bs -> Ok (Frame.Headers bs))
          (if priority then advance 5 *> take_bigstring_unsafe (length - 5)
           else take_bigstring_unsafe length)
      in
      parse_padded_payload frame_header parse_headers

let parse_priority_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ -> lift (fun () -> Ok Frame.Priority) parse_priority

let parse_error_code = lift Error_code.parse BE.any_int32

let parse_rst_stream_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      lift (fun error_code -> Ok (Frame.RSTStream error_code)) parse_error_code

let parse_settings_payload num_settings =
  let open Angstrom in
  let open Settings in
  let rec parse_inner acc remaining =
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
          | _ -> acc)
        BE.any_uint16 BE.any_int32
      >>= fun acc' -> parse_inner acc' (remaining - 1)
  in
  parse_inner [] num_settings

let parse_settings_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      let num_settings = payload_length / Settings.octets_per_setting in
      parse_settings_payload num_settings >>| fun xs -> Ok (Frame.Settings xs)

let parse_push_promise_frame frame_header =
  let { Frame.payload_length; _ } = frame_header in
  match Frame.validate_header frame_header with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      let parse_push_promise length =
        lift2
          (fun promised_stream_id fragment ->
            if Stream_identifier.is_connection promised_stream_id then
              connection_error ProtocolError
                "PUSH must not promise stream id 0x0"
            else if Stream_identifier.is_client promised_stream_id then
              connection_error ProtocolError
                "PUSH must be associated with an even-numbered stream id"
            else Ok Frame.(PushPromise (promised_stream_id, fragment)))
          stream_identifier
          (take_bigstring_unsafe (length - 4))
      in
      parse_padded_payload frame_header parse_push_promise

let parse_ping_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      lift (fun bs -> Ok (Frame.Ping bs)) (take_bigstring_unsafe payload_length)

let parse_go_away_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      lift3
        (fun last_stream_id err debug_data ->
          Ok (Frame.GoAway (last_stream_id, err, debug_data)))
        stream_identifier parse_error_code
        (take_bigstring_unsafe (payload_length - 8))

let[@inline] clear_bit_int32 x i =
  let open Int32 in
  logand x (lognot (shift_left 1l i))

let parse_window_update_frame
    ({ Frame.stream_id; payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      lift
        (fun uint ->
          let window_size_increment = clear_bit_int32 uint 31 in
          if Int32.equal window_size_increment 0l then
            if Stream_identifier.is_connection stream_id then
              connection_error ProtocolError "Window update must not be 0"
            else stream_error ProtocolError stream_id
          else Ok (Frame.WindowUpdate window_size_increment))
        BE.any_int32

let parse_continuation_frame ({ Frame.payload_length; _ } as headers) =
  match Frame.validate_header headers with
  | Error _ as err -> advance payload_length >>| fun () -> err
  | Ok _ ->
      lift
        (fun block_fragment -> Ok (Frame.Continuation block_fragment))
        (take_bigstring_unsafe payload_length)

let parse_unknown_frame typ { Frame.payload_length; _ } =
  lift
    (fun bigstring -> Ok (Frame.Unknown (typ, bigstring)))
    (take_bigstring_unsafe payload_length)

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
