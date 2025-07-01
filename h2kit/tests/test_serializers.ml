open H2kit
open Utils
module Serializers = Serializers.Make (Faraday)

module Testable = struct
  let pp_cs fmt cs = Format.fprintf fmt "%s" (Cstruct.to_string cs)
  let cstruct = Alcotest.testable pp_cs Cstruct.equal
  let string = Alcotest.string
end

let serialize_to_string writer =
  let f = Faraday.create 1024 in
  writer f;
  Faraday.serialize_to_string f

let serialize_to_cstruct writer =
  let f = Faraday.create 1024 in
  writer f;
  let bigstr = Faraday.serialize_to_bigstring f in
  Cstruct.of_bigarray bigstr

(*******************************************************************************)
(*                                    TESTS                                    *)
(*******************************************************************************)

let test_connection_preface () =
  let result = serialize_to_string Serializers.write_connection_preface in
  let expected = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" in
  Alcotest.(check Testable.string)
    "Connection preface serialization" expected result

let test_data_frame_payload () =
  let data1 = "hello" in
  let data2 = " world" in
  let cs_list = [ Cstruct.of_string data1; Cstruct.of_string data2 ] in
  let result =
    serialize_to_cstruct (Serializers.LowLevel.write_data_frame_payload cs_list)
  in

  let expected = Cstruct.of_string (data1 ^ data2) in

  Alcotest.check Testable.cstruct "DATA frame payload" expected result

let test_data_frame_simple () =
  let stream_id = 1l in
  let data = "mangerzzz" in
  let cs = Cstruct.of_string data in
  let info = Serializers.create_frame_info stream_id in

  let result =
    serialize_to_cstruct (fun f -> Serializers.write_data_frame [ cs ] info f)
  in

  let expected_header =
    make_header_cs ~payload_length:(String.length data)
      ~frame_type:Frame.FrameType.Data ~flags:Flags.default_flags ~stream_id
  in
  let expected_payload = Cstruct.of_string data in
  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "Simple DATA frame" expected result

let test_data_frame_with_padding () =
  let stream_id = 3l in
  let data = "pizzunia" in
  let cs_data = Cstruct.of_string data in
  let padding_length = 5 in
  let flags = Flags.default_flags in
  let info = Serializers.create_frame_info ~flags ~padding_length stream_id in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_data_frame [ cs_data ] info f)
  in

  let expected_header =
    make_header_cs
      ~payload_length:(String.length data + padding_length + 1)
      ~frame_type:Frame.FrameType.Data ~flags:(Flags.set_padded flags)
      ~stream_id
  in

  let expected_payload =
    Cstruct.create (String.length data + padding_length + 1)
  in
  Cstruct.set_uint8 expected_payload 0 padding_length;
  Cstruct.blit_from_string data 0 expected_payload 1 (String.length data);

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "Padded DATA frame" expected result

let test_data_frame_multiple_cstructs () =
  let stream_id = 2l in
  let data1 = "Loli" in
  let data2 = "gagging" in
  let cs_list = [ Cstruct.of_string data1; Cstruct.of_string data2 ] in
  let info = Serializers.create_frame_info stream_id in

  let result =
    serialize_to_cstruct (fun f -> Serializers.write_data_frame cs_list info f)
  in

  let total_length = String.length data1 + String.length data2 in
  let expected_header =
    make_header_cs ~payload_length:total_length ~frame_type:Frame.FrameType.Data
      ~flags:Flags.default_flags ~stream_id
  in
  let expected_payload = Cstruct.of_string (data1 ^ data2) in
  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct)
    "DATA frame from multiple cstructs" expected result

let test_rst_stream_frame_payload () =
  let error_code = Error_code.InternalError in

  let result =
    serialize_to_cstruct
      (Serializers.LowLevel.write_rst_stream_frame_payload error_code)
  in

  let expected = Cstruct.create 4 in
  Cstruct.BE.set_uint32 expected 0 (Error_code.serialize error_code);

  Alcotest.check Testable.cstruct "RST_STREAM frame payload" expected result

let test_rst_stream_frame () =
  let stream_id = 7l in
  let error_code = Error_code.Cancel in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_rst_stream_frame stream_id error_code f)
  in

  let expected_header =
    make_header_cs ~payload_length:4 ~frame_type:Frame.FrameType.RSTStream
      ~flags:Flags.default_flags ~stream_id
  in

  let expected_payload = Cstruct.create 4 in
  Cstruct.BE.set_uint32 expected_payload 0 (Error_code.serialize error_code);

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "RST_STREAM frame" expected result

let test_settings_frame_payload () =
  let settings =
    [
      Settings.EnablePush 0;
      Settings.MaxConcurrentStreams 2048l;
      Settings.InitialWindowSize 100_000l;
    ]
  in

  let result =
    serialize_to_cstruct
      (Serializers.LowLevel.write_settings_frame_payload settings)
  in

  let expected = Cstruct.create (List.length settings * 6) in
  Cstruct.BE.set_uint16 expected 0
    (Settings.serialize_key (Settings.EnablePush 0));
  Cstruct.BE.set_uint32 expected 2 0l;
  Cstruct.BE.set_uint16 expected 6
    (Settings.serialize_key (Settings.MaxConcurrentStreams 2048l));
  Cstruct.BE.set_uint32 expected 8 2048l;
  Cstruct.BE.set_uint16 expected 12
    (Settings.serialize_key (Settings.InitialWindowSize 100_000l));
  Cstruct.BE.set_uint32 expected 14 100_000l;

  Alcotest.check Testable.cstruct "SETTINGS frame payload" expected result

let test_settings_frame () =
  let stream_id = 0l in
  let settings = [ Settings.HeaderTableSize 4096; Settings.EnablePush 1 ] in
  let info = Serializers.create_frame_info stream_id in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_settings_frame settings info f)
  in

  let expected_header =
    make_header_cs
      ~payload_length:(List.length settings * 6)
      ~frame_type:Frame.FrameType.Settings ~flags:Flags.default_flags ~stream_id
  in

  let expected_payload = Cstruct.create (List.length settings * 6) in
  Cstruct.BE.set_uint16 expected_payload 0
    (Settings.serialize_key (Settings.HeaderTableSize 0));
  Cstruct.BE.set_uint32 expected_payload 2 (Int32.of_int 4096);
  Cstruct.BE.set_uint16 expected_payload 6
    (Settings.serialize_key (Settings.EnablePush 0));
  Cstruct.BE.set_uint32 expected_payload 8 (Int32.of_int 1);

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "SETTINGS frame" expected result

let test_settings_ack_frame () =
  let stream_id = 0l in
  let flags = Flags.set_ack Flags.default_flags in
  let info = Serializers.create_frame_info ~flags stream_id in

  let result =
    serialize_to_cstruct (fun f -> Serializers.write_settings_frame [] info f)
  in

  let expected_header =
    make_header_cs ~payload_length:0 ~frame_type:Frame.FrameType.Settings ~flags
      ~stream_id
  in

  Alcotest.(check Testable.cstruct) "SETTINGS ACK frame" expected_header result

let test_ping_frame () =
  let stream_id = 0l in
  let opaque_data = "zucczucc" in
  let cs_data = Cstruct.of_string opaque_data in
  let info = Serializers.create_frame_info stream_id in

  let result =
    serialize_to_cstruct (fun f -> Serializers.write_ping_frame cs_data info f)
  in

  let expected_header =
    make_header_cs ~payload_length:8 ~frame_type:Frame.FrameType.Ping
      ~flags:Flags.default_flags ~stream_id
  in

  let expected_payload = Cstruct.create 8 in
  Cstruct.blit_from_string opaque_data 0 expected_payload 0 8;

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "PING frame" expected result

let test_ping_ack_frame () =
  let stream_id = 0l in
  let opaque_data = "zucczucc" in
  let cs_data = Cstruct.of_string opaque_data in
  let flags = Flags.set_ack Flags.default_flags in
  let info = Serializers.create_frame_info ~flags stream_id in

  let result =
    serialize_to_cstruct (fun f -> Serializers.write_ping_frame cs_data info f)
  in

  let expected_header =
    make_header_cs ~payload_length:8 ~frame_type:Frame.FrameType.Ping ~flags
      ~stream_id
  in

  let expected_payload = Cstruct.create 8 in
  Cstruct.blit_from_string opaque_data 0 expected_payload 0 8;

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "PING ACK frame" expected result

let test_goaway_frame_payload () =
  let last_stream_id = 11l in
  let error_code = Error_code.CompressionError in
  let debug_data = "oh no!" in
  let cs_debug = Cstruct.of_string debug_data in

  let result =
    serialize_to_cstruct
      (Serializers.LowLevel.write_goaway_frame_payload ~debug_data:cs_debug
         last_stream_id error_code)
  in

  let expected = Cstruct.create (8 + String.length debug_data) in
  Cstruct.BE.set_uint32 expected 0 last_stream_id;
  Cstruct.BE.set_uint32 expected 4 (Error_code.serialize error_code);
  Cstruct.blit_from_string debug_data 0 expected 8 (String.length debug_data);

  Alcotest.check Testable.cstruct "GOAWAY frame payload" expected result

let test_goaway_frame () =
  let last_stream_id = 15l in
  let error_code = Error_code.ProtocolError in
  let debug_data = "erra D:" in
  let cs_debug = Cstruct.of_string debug_data in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_goaway_frame ~debug_data:cs_debug last_stream_id
          error_code f)
  in

  let expected_header =
    make_header_cs
      ~payload_length:(8 + String.length debug_data)
      ~frame_type:Frame.FrameType.GoAway ~flags:Flags.default_flags
      ~stream_id:Stream_identifier.connection
  in

  let expected_payload = Cstruct.create (8 + String.length debug_data) in
  Cstruct.BE.set_uint32 expected_payload 0 last_stream_id;
  Cstruct.BE.set_uint32 expected_payload 4 (Error_code.serialize error_code);
  Cstruct.blit_from_string debug_data 0 expected_payload 8
    (String.length debug_data);

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct)
    "GOAWAY frame with debug data" expected result

let test_goaway_frame_no_debug () =
  let last_stream_id = 7l in
  let error_code = Error_code.InternalError in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_goaway_frame last_stream_id error_code f)
  in

  let expected_header =
    make_header_cs ~payload_length:8 ~frame_type:Frame.FrameType.GoAway
      ~flags:Flags.default_flags ~stream_id:Stream_identifier.connection
  in

  let expected_payload = Cstruct.create 8 in
  Cstruct.BE.set_uint32 expected_payload 0 last_stream_id;
  Cstruct.BE.set_uint32 expected_payload 4 (Error_code.serialize error_code);

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct)
    "GOAWAY frame without debug data" expected result

let test_window_update_frame_payload () =
  let increment = 500_000l in

  let result =
    serialize_to_cstruct
      (Serializers.LowLevel.write_window_update_frame_payload increment)
  in

  let expected = Cstruct.create 4 in
  Cstruct.BE.set_uint32 expected 0 increment;

  Alcotest.check Testable.cstruct "WINDOW_UPDATE frame payload" expected result

let test_window_update_frame () =
  let stream_id = 1l in
  let increment = 1000l in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_window_update_frame stream_id increment f)
  in

  let expected_header =
    make_header_cs ~payload_length:4 ~frame_type:Frame.FrameType.WindowUpdate
      ~flags:Flags.default_flags ~stream_id
  in

  let expected_payload = Cstruct.create 4 in
  Cstruct.BE.set_uint32 expected_payload 0 increment;

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct) "WINDOW_UPDATE frame" expected result

let test_window_update_connection_level () =
  let stream_id = Stream_identifier.connection in
  let increment = 65535l in

  let result =
    serialize_to_cstruct (fun f ->
        Serializers.write_window_update_frame stream_id increment f)
  in

  let expected_header =
    make_header_cs ~payload_length:4 ~frame_type:Frame.FrameType.WindowUpdate
      ~flags:Flags.default_flags ~stream_id
  in

  let expected_payload = Cstruct.create 4 in
  Cstruct.BE.set_uint32 expected_payload 0 increment;

  let expected = Cstruct.append expected_header expected_payload in

  Alcotest.(check Testable.cstruct)
    "WINDOW_UPDATE connection-level" expected result

let test_roundtrip_data_frame () =
  let stream_id = 5l in
  let data = "Round-trip test data" in
  let cs_data = Cstruct.of_string data in
  let info = Serializers.create_frame_info stream_id in

  let serialized =
    serialize_to_string (fun f ->
        Serializers.write_data_frame [ cs_data ] info f)
  in

  let bs =
    Bigstringaf.of_string ~off:0 ~len:(String.length serialized) serialized
  in
  let parsed_result =
    Angstrom.parse_bigstring ~consume:All Parsers.parse_frame bs
  in

  match parsed_result with
  | Ok (Ok frame) ->
      let expected_frame =
        {
          Frame.frame_header =
            {
              payload_length = String.length data;
              flags = Flags.default_flags;
              stream_id;
              frame_type = Frame.FrameType.Data;
            };
          frame_payload = Frame.Data (Cstruct.of_string data);
        }
      in
      Alcotest.(check bool)
        "Round-trip DATA frame parsing" true
        (Frame.equal frame expected_frame)
  | _ -> Alcotest.failf "Failed to parse serialized DATA frame"

let test_roundtrip_rst_stream_frame () =
  let stream_id = 3l in
  let error_code = Error_code.StreamClosed in

  let serialized =
    serialize_to_string (fun f ->
        Serializers.write_rst_stream_frame stream_id error_code f)
  in

  let bs =
    Bigstringaf.of_string ~off:0 ~len:(String.length serialized) serialized
  in
  let parsed_result =
    Angstrom.parse_bigstring ~consume:All Parsers.parse_frame bs
  in

  match parsed_result with
  | Ok (Ok frame) ->
      let expected_frame =
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
      Alcotest.(check bool)
        "Round-trip RST_STREAM frame parsing" true
        (Frame.equal frame expected_frame)
  | _ -> Alcotest.failf "Failed to parse serialized RST_STREAM frame"

let () =
  let open Alcotest in
  run "H2kit.Serializers"
    [
      ( "Connection",
        [ test_case "Connection Preface" `Quick test_connection_preface ] );
      ( "Frame payloads",
        [
          test_case "DATA" `Quick test_data_frame_payload;
          test_case "RST_STREAM" `Quick test_rst_stream_frame_payload;
          test_case "SETTINGS" `Quick test_settings_frame_payload;
          test_case "GOAWAY" `Quick test_goaway_frame_payload;
          test_case "WINDOW_UPDATE" `Quick test_window_update_frame_payload;
        ] );
      ( "DATA Frames",
        [
          test_case "DATA" `Quick test_data_frame_simple;
          test_case "Padded DATA" `Quick test_data_frame_with_padding;
          test_case "Multiple Cstructs DATA" `Quick
            test_data_frame_multiple_cstructs;
        ] );
      ( "Control Frames",
        [
          test_case "RST_STREAM" `Quick test_rst_stream_frame;
          test_case "SETTINGS" `Quick test_settings_frame;
          test_case "SETTINGS ACK" `Quick test_settings_ack_frame;
          test_case "PING" `Quick test_ping_frame;
          test_case "PING ACK" `Quick test_ping_ack_frame;
          test_case "GOAWAY with debug" `Quick test_goaway_frame;
          test_case "GOAWAY without debug" `Quick test_goaway_frame_no_debug;
          test_case "WINDOW_UPDATE" `Quick test_window_update_frame;
          test_case "WINDOW_UPDATE connection" `Quick
            test_window_update_connection_level;
        ] );
      ( "Round-trip Tests",
        [
          test_case "DATA round-trip" `Quick test_roundtrip_data_frame;
          test_case "RST_STREAM round-trip" `Quick
            test_roundtrip_rst_stream_frame;
        ] );
    ]
