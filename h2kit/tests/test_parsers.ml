open Angstrom
open H2kit
open Utils

module Testable = struct
  let h2_frame =
    let open Frame in
    Alcotest.testable pp equal

  let h2_error =
    let open Error in
    Alcotest.testable pp equal

  let parse_result = Alcotest.result h2_frame h2_error
end

let build_frame ?(flags = Flags.default_flags) ~stream_id frame_type payload_str
    =
  let header_cs =
    make_header_cs ~stream_id ~frame_type
      ~payload_length:(String.length payload_str)
      ~flags
  in
  Cstruct.to_string header_cs ^ payload_str

let run_parser p s =
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length s) s in
  match parse_bigstring ~consume:All p bs with
  | Ok res -> res
  | Error msg -> Alcotest.failf "Internal Angstrom parser failure: %s" msg

(*******************************************************************************)
(*                                    TESTS                                    *)
(*******************************************************************************)

let test_connection_preface () =
  let preface = Frame.connection_preface in
  let result = parse_string ~consume:All Parsers.connection_preface preface in
  Alcotest.(check (result string string))
    "Correctly parses the connection preface" (Ok preface) result;

  let bad_preface = "GET / HTTP/1.1\r\n\r\n" in
  let result =
    parse_string ~consume:All Parsers.connection_preface bad_preface
  in
  Alcotest.(check bool)
    "Fails to parse an invalid preface" (Result.is_error result) true

(** Tests for DATA frames. *)
let test_data_frame () =
  let stream_id = 1l in
  let payload = "Hello, this is some data." in
  let frame_str = build_frame ~stream_id Frame.FrameType.Data payload in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = String.length payload;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.Data;
          };
        frame_payload =
          Frame.Data
            (Cstruct.of_string ~off:0 ~len:(String.length payload) payload);
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "Simple DATA frame" expected result

let test_padded_data_frame () =
  let stream_id = 3l in
  let flags = Flags.set_padded Flags.default_flags in
  let data = "some content" in
  let pad_len = 8 in
  let payload_str =
    String.make 1 (char_of_int pad_len) ^ data ^ String.make pad_len '\x00'
  in
  let frame_str =
    build_frame ~flags ~stream_id Frame.FrameType.Data payload_str
  in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = String.length payload_str;
            flags;
            stream_id;
            frame_type = Frame.FrameType.Data;
          };
        frame_payload =
          Frame.Data (Cstruct.of_string ~off:0 ~len:(String.length data) data);
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "Padded DATA frame returns full payload" expected result

(** Tests for HEADERS frames. *)
let test_headers_frame () =
  let stream_id = 5l in
  let flags = Flags.(set_end_header (set_end_stream default_flags)) in
  let fragment = "\x82\x86\x41\x8a\x0d\x7c\xeb\x91\x3b\x6f" in
  let frame_str =
    build_frame ~flags ~stream_id Frame.FrameType.Headers fragment
  in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = String.length fragment;
            flags;
            stream_id;
            frame_type = Frame.FrameType.Headers;
          };
        frame_payload =
          Frame.Headers
            (Bigstringaf.of_string ~off:0 ~len:(String.length fragment) fragment);
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "HEADERS frame with two flags" expected result

(** Tests for PRIORITY frames. *)
let test_priority_frame () =
  let stream_id = 7l in
  let payload =
    let cs = Cstruct.create 5 in
    Cstruct.BE.set_uint32 cs 0 0x80000003l;
    Cstruct.set_uint8 cs 4 199;
    Cstruct.to_string cs
  in
  let frame_str = build_frame ~stream_id Frame.FrameType.Priority payload in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = 5;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.Priority;
          };
        frame_payload = Frame.Priority;
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "PRIORITY frame" expected result

(** Tests for RST_STREAM frames. *)
let test_rst_stream_frame () =
  let stream_id = 9l in
  let error_code = Error_code.Cancel in
  let payload =
    let cs = Cstruct.create 4 in
    Cstruct.BE.set_uint32 cs 0 (Error_code.serialize error_code);
    Cstruct.to_string cs
  in
  let frame_str = build_frame ~stream_id Frame.FrameType.RSTStream payload in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = 4;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.RSTStream;
          };
        frame_payload = Frame.RSTStream error_code;
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "RST_STREAM frame" expected result

(** Tests for SETTINGS frames. *)
let test_settings_frame () =
  let stream_id = 0l in
  let settings_payload =
    let cs = Cstruct.create 12 in
    Cstruct.BE.set_uint16 cs 0
      (Settings.serialize_key (Settings.HeaderTableSize 0));
    Cstruct.BE.set_uint32 cs 2 4096l;
    Cstruct.BE.set_uint16 cs 6 (Settings.serialize_key (Settings.EnablePush 0));
    Cstruct.BE.set_uint32 cs 8 0l;
    Cstruct.to_string cs
  in
  let frame_str =
    build_frame ~stream_id Frame.FrameType.Settings settings_payload
  in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = 12;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.Settings;
          };
        frame_payload = Frame.Settings [ HeaderTableSize 4096; EnablePush 0 ];
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "SETTINGS frame with values" expected result

let test_settings_ack_frame () =
  let stream_id = 0l in
  let flags = Flags.(set_ack default_flags) in
  let frame_str = build_frame ~flags ~stream_id Frame.FrameType.Settings "" in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = 0;
            flags;
            stream_id;
            frame_type = Frame.FrameType.Settings;
          };
        frame_payload = Frame.Settings [];
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "SETTINGS ACK frame" expected result

(** Tests for PING frames. *)
let test_ping_frame () =
  let stream_id = 0l in
  let opaque_data = "nenersss" in
  let frame_str = build_frame ~stream_id Frame.FrameType.Ping opaque_data in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = 8;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.Ping;
          };
        frame_payload =
          Frame.Ping (Bigstringaf.of_string ~off:0 ~len:8 opaque_data);
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "PING frame" expected result

(** Tests for GOAWAY frames. *)
let test_goaway_frame () =
  let stream_id = 0l in
  let last_stream_id = 15l in
  let error_code = Error_code.ProtocolError in
  let debug_data = "debug message" in
  let payload =
    let cs = Cstruct.create (8 + String.length debug_data) in
    Cstruct.BE.set_uint32 cs 0 last_stream_id;
    Cstruct.BE.set_uint32 cs 4 (Error_code.serialize error_code);
    Cstruct.blit_from_string debug_data 0 cs 8 (String.length debug_data);
    Cstruct.to_string cs
  in
  let frame_str = build_frame ~stream_id Frame.FrameType.GoAway payload in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = String.length payload;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.GoAway;
          };
        frame_payload =
          Frame.GoAway
            ( last_stream_id,
              error_code,
              Bigstringaf.of_string ~off:0 ~len:(String.length debug_data)
                debug_data );
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "GOAWAY frame" expected result

(** Tests for WINDOW_UPDATE frames. *)
let test_window_update_frame () =
  let stream_id = 1l in
  let increment = 1000l in
  let payload =
    let cs = Cstruct.create 4 in
    Cstruct.BE.set_uint32 cs 0 increment;
    Cstruct.to_string cs
  in
  let frame_str = build_frame ~stream_id Frame.FrameType.WindowUpdate payload in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = 4;
            flags = Flags.default_flags;
            stream_id;
            frame_type = Frame.FrameType.WindowUpdate;
          };
        frame_payload = Frame.WindowUpdate increment;
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "WINDOW_UPDATE on stream" expected result

(** Tests for CONTINUATION frames. *)
let test_continuation_frame () =
  let stream_id = 5l in
  let flags = Flags.set_end_header Flags.default_flags in
  let fragment =
    "\x04\x0a\x77\x77\x77\x2e\x65\x78\x61\x6d\x70\x6c\x65\x2e\x63\x6f\x6d"
  in
  let frame_str =
    build_frame ~flags ~stream_id Frame.FrameType.Continuation fragment
  in
  let expected =
    Ok
      {
        Frame.frame_header =
          {
            payload_length = String.length fragment;
            flags;
            stream_id;
            frame_type = Frame.FrameType.Continuation;
          };
        frame_payload =
          Frame.Continuation
            (Bigstringaf.of_string ~off:0 ~len:(String.length fragment) fragment);
      }
  in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result) "CONTINUATION frame" expected result

let test_invalid_stream_id_for_settings () =
  let frame_str = build_frame ~stream_id:1l Frame.FrameType.Settings "" in
  let expected = Error (Error.conn_prot_err ProtocolError "") in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "SETTINGS on non-zero stream" expected result

let test_invalid_stream_id_for_ping () =
  let frame_str = build_frame ~stream_id:1l Frame.FrameType.Ping "12345678" in
  let expected = Error (Error.conn_prot_err ProtocolError "") in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "PING on non-zero stream" expected result

let test_invalid_payload_size_for_rst_stream () =
  let frame_str = build_frame ~stream_id:3l Frame.FrameType.RSTStream "short" in
  let expected = Error (Error.conn_prot_err FrameSizeError "") in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "RST_STREAM with wrong payload size" expected result

let test_invalid_payload_size_for_window_update () =
  let frame_str =
    build_frame ~stream_id:3l Frame.FrameType.WindowUpdate "too long"
  in
  let expected = Error (Error.conn_prot_err FrameSizeError "") in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "WINDOW_UPDATE with wrong payload size" expected result

let test_window_update_with_zero_increment () =
  let stream_id = 1l in
  let payload =
    let cs = Cstruct.create 4 in
    Cstruct.BE.set_uint32 cs 0 0l;
    Cstruct.to_string cs
  in
  let frame_str = build_frame ~stream_id Frame.FrameType.WindowUpdate payload in
  let expected = Error (Error.stream_prot_err stream_id ProtocolError) in
  let result = run_parser Parsers.parse_frame frame_str in
  Alcotest.(check Testable.parse_result)
    "WINDOW_UPDATE with zero increment" expected result

let () =
  let open Alcotest in
  run "H2kit.Parsers"
    [
      ( "Connection",
        [ test_case "Connection Preface" `Quick test_connection_preface ] );
      ( "Valid Frames",
        [
          test_case "DATA" `Quick test_data_frame;
          test_case "Padded DATA" `Quick test_padded_data_frame;
          test_case "HEADERS" `Quick test_headers_frame;
          test_case "PRIORITY" `Quick test_priority_frame;
          test_case "RST_STREAM" `Quick test_rst_stream_frame;
          test_case "SETTINGS" `Quick test_settings_frame;
          test_case "SETTINGS ACK" `Quick test_settings_ack_frame;
          test_case "PING" `Quick test_ping_frame;
          test_case "GOAWAY" `Quick test_goaway_frame;
          test_case "WINDOW_UPDATE" `Quick test_window_update_frame;
          test_case "CONTINUATION" `Quick test_continuation_frame;
        ] );
      ( "Error Handling",
        [
          test_case "Invalid stream id for SETTINGS" `Quick
            test_invalid_stream_id_for_settings;
          test_case "Invalid stream id for PING" `Quick
            test_invalid_stream_id_for_ping;
          test_case "Invalid size for RST_STREAM" `Quick
            test_invalid_payload_size_for_rst_stream;
          test_case "Invalid size for WINDOW_UPDATE" `Quick
            test_invalid_payload_size_for_window_update;
          test_case "WINDOW_UPDATE with 0 increment" `Quick
            test_window_update_with_zero_increment;
        ] );
    ]
