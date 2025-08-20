open H2kit
open Runner
open Branch
open Event
module W = Writer
module Serializers = Serializers.Make (Buf_write)
module Case = Case
module Event = Event

let run_server_tests ?(first_port = 8050) ~sw clock net =
  let connection_preface : test_group =
    test_group "Connection preface"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Initialization, standard preface exchange"
          ~desc:
            {|[Section 3.4. of RFC9113] "In HTTP/2, each endpoint is required to send a connection preface as a final confirmation of the protocol in use and to establish th initial settings for the HTTP/2 connection."|}
          (preface
          @ [
              single
                (frame_header ~flags:Flags.(default_flags |> set_ack) Settings);
              write W.(goaway NoError);
              single eof;
            ]);
        test "Server sends invalid connection preface"
          ~desc:
            {|[Section 3.4 of RFC9113] "The server connection preface consists of a potentially empty SETTINGS frame (Section 6.5) that MUST be @{<ul>the first frame the server sends@} in the HTTP/2 connection. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|}
          [
            ??magic;
            ??settings;
            !!W.(ping "12345678");
            ??(goaway_code ProtocolError);
            ??eof;
          ];
        test "Server acknowledges client's SETTINGS before sending its preface"
          ~desc:
            {|[Section 3.4. of RFC9113] "The SETTINGS frames received from a peer as part of the connection preface MUST be acknowledged (see Section 6.5.3) @{<ul>after@} sending the connection preface. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|}
          [
            single magic;
            single settings;
            write W.(settings ~flags:Flags.(default_flags |> set_ack) []);
            single (goaway_code ProtocolError);
            single eof;
          ];
      ]
  in

  let frame_header_validation : test_group =
    test_group "Frame header validation"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Server sends a frame with unknown frame type"
          ~desc:
            {|[Section 4.1. of RFC9113] "Type: The 8-bit type of the frame. The frame type determines the format and semantics of the frame. Frames defined in this document are listed in Section 6. Implementations MUST @{<ul>ignore and discard@} frames of unknown types."|}
          [
            single magic;
            single settings;
            write
              W.(
                settings [] ++ unknown
                ++ settings ~flags:Flags.(default_flags |> set_ack) []);
            single settings_ack;
            write W.(goaway NoError);
            single eof;
          ];
      ]
  in

  let connection_frames_validation : test_group =
    test_group "Parsing and validating connection-level frames"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test
          "Server sends a SETTINGS frame with ACK flag and payload length > 0"
          ~desc:
            {|ACK (0x01): "[...] Receipt of a SETTINGS frame with the ACK flag set and a length field value other than 0 MUST be treated as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR."|}
          (conn_only
          @ [
              write
                W.(
                  settings
                    ~flags:Flags.(default_flags |> set_ack)
                    [ MaxConcurrentStreams 100l ]);
              single (goaway_code FrameSizeError);
              single eof;
            ]);
        test "Server sends a SETTINGS frame with stream id != 0"
          ~desc:
            {|[Section 6.5. pf RFC9113] "SETTINGS frames always apply to a connection, never a single stream. The @{<ul>stream identifier@} for a SETTINGS frame @{<ul>MUST be zero (0x00)@}. If an endpoint receives a SETTINGS frame whose Stream Identifier field is anything other than 0x00, the endpoint MUST respond with a connection error (Section 5.4.1) of type @{<ul>PROTOCOL_ERROR@}."|}
          (conn_only
          @ [
              write (W.settings ~id:1l []);
              single (goaway_code ProtocolError);
              single eof;
            ]);
        test
          "Server sends a SETTINGS frame with one setting with an unknown \
           identifier"
          ~desc:
            {|[Section 6.5.2. of RFC9113] "An endpoint that receives a SETTINGS frame with any unknown or unsupported identifier MUST @{<ul>ignore@} that setting."|}
          (conn_only
          @ [ write W.unknown_setting; single settings_ack ]
          @ grace_end);
        test "Server sends a SETTINGS frame with custom, valid values"
          (conn_only
          @ [
              write
                W.(
                  settings
                    [
                      MaxConcurrentStreams 2000l;
                      InitialWindowSize 131_070l;
                      MaxFrameSize 163_840;
                      MaxHeaderListSize 1000;
                    ]);
              single settings_ack;
            ]
          @ grace_end);
        test
          "Server sends a SETTINGS frame with ENABLE_PUSH setting set to value \
           > 1"
          ~desc:
            {|[Section 6.5.2.] "SETTINGS_ENABLE_PUSH (0x02): [...] Any value other than 0 or 1 MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|}
          (conn_only
          @ [
              write (W.settings [ EnablePush 2 ]);
              single (goaway_code ProtocolError);
              single eof;
            ]);
        test
          "Server sends a SETTINGS frame with ENABLE_PUSH setting set to value \
           1"
          ~desc:
            {|[Section 6.5.2.] "SETTINGS_ENABLE_PUSH (0x02): [...] A server MUST NOT explicitly set this value to 1. [...] A client MUST treat receipt of a SETTINGS frame with SETTINGS_ENABLE_PUSH set to 1 as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|}
          (conn_only
          @ [
              write (W.settings [ EnablePush 1 ]);
              single (goaway_code ProtocolError);
              single eof;
            ]);
        test
          "Server sends a SETTINGS frame with INITIAL_WINDOW_SIZE setting set \
           to value > 2^31-1"
          ~desc:
            {|[Section 6.5.2.] "SETTINGS_INITIAL_WINDOW_SIZE (0x04): [...] Values above the maximum flow-control window size of 2^31-1 MUST be treated as a connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR."|}
          (conn_only
          @ [
              write
                W.(settings [ InitialWindowSize (Int32.add 2_147_483_647l 1l) ]);
              single (goaway_code ProtocolError);
              single eof;
            ]);
        test
          "Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set to \
           value < 16384"
          ~desc:
            {|[Section 6.5.2.] "SETTINGS_MAX_FRAME_SIZE (0x05): [...] The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (224-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|}
          (conn_only
          @ [
              write W.(settings [ MaxFrameSize 16_383 ]);
              single (goaway_code ProtocolError);
              single eof;
            ]);
        test
          "Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set to \
           value > 2^24-1"
          ~desc:
            {|[Section 6.5.2.] "SETTINGS_MAX_FRAME_SIZE (0x05): [...] The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (2^24-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|}
          (conn_only
          @ [
              !!W.(settings [ MaxFrameSize 16_777_216 ]);
              ??(goaway_code ProtocolError);
              ??eof;
            ]);
        test "Server sends a PING frame with stream id != 0"
          (conn_only
          @ [
              !!W.(ping ~id:1l "12345678"); ??(goaway_code ProtocolError); ??eof;
            ]);
        test "Server sends a PING frame with payload length != 8"
          (conn_only
          @ [
              !!W.(ping ~len:5 "12345678");
              ??(goaway_code FrameSizeError);
              ??eof;
            ]);
        test "Server sends a GOAWAY frame with stream id != 0"
          (conn_only
          @ [
              !!W.(goaway ~id:1l NoError); ??(goaway_code ProtocolError); ??eof;
            ]);
        test "Server sends a GOAWAY frame with unknown error code"
          (conn_only
          @ [
              !!W.(goaway (UnknownError_code 20l));
              (* TODO: should also single GOAWAY I think *)
              ??eof;
            ]);
        test
          "Server sends a WINDOW_UPDATE frame with a valid window size \
           increment value and stream id = 0"
          (conn_only @ [ !!W.(window_update 1024l) ] @ grace_end);
        test "Server sends a WINDOW_UPDATE frame with payload length != 4"
          (conn_only
          @ [
              !!W.(window_update ~len:3 1024l);
              ??(goaway_code FrameSizeError);
              ??eof;
            ]);
        test
          "Server sends a WINDOW_UPDATE frame with window size increment value \
           = 0 and stream id = 0"
          (conn_only
          @ [
              !!W.(window_update ~id:0l 0l);
              ??(goaway_code ProtocolError);
              ??eof;
            ]);
      ]
  in

  let stream_frames_validation : test_group =
    test_group
      ~ignore:Ignore.(frame_type WindowUpdate)
      ~streams:[ GET "/" ] "Parsing and validating stream-level frames"
      [
        test
          "Server responds with a final 200 code HEADERS frame with END_STREAM \
           flag"
          (with_preface
             [ ??headers; !!W.(headers (`List [ (":status", "200") ])) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server responds with a HEADERS frame with stream id = 0"
          (with_preface
             [ !!W.(headers ~id:0l (`List [ (":status", "200") ])) ]
             [ ??(goaway_code ProtocolError); ??eof ]);
        test
          "Server responds with a HEADERS frame with padding length > payload \
           length"
          (with_preface
             [
               ??headers;
               !!W.(
                   headers
                     ~flags:
                       Flags.(
                         default_flags |> set_end_header |> set_end_stream
                         |> set_padded)
                     ~pad_len:50
                     (`List [ (":status", "200") ]));
             ]
             [ ??(goaway_code ProtocolError); ??eof ]);
        test "Server responds with a HEADERS frame with invalid headers block"
          (with_preface
             [
               ??headers;
               !!W.(headers (`Block (Cstruct.of_hex "400A686561646572")));
             ]
             [ ??(goaway_code CompressionError); ??eof ]);
        test "Server sends a WINDOW_UPDATE frame before responding with HEADERS"
          (with_preface
             [
               ??headers;
               !!W.(
                   window_update ~id:1l 1024l
                   ++ headers (`List [ (":status", "200") ]));
             ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends a RST_STREAM frame"
          (with_preface
             [ ??headers; !!W.(rst_stream NoError) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends a RST_STREAM with stream id = 0"
          (with_preface
             [ ??headers; !!W.(rst_stream ~id:0l NoError) ]
             [ ??(goaway_code ProtocolError); ??eof ]);
        test "Server sends a RST_STREAM with payload length != 4"
          (with_preface
             [ ??headers; !!W.(rst_stream ~len:3 NoError) ]
             [ ??(goaway_code FrameSizeError); ??eof ]);
        test "Server sends a DATA frame"
          (with_preface
             [
               ??headers;
               !!W.(
                   headers
                     ~flags:Flags.(default_flags |> set_end_header)
                     (`List [ (":status", "200") ])
                   ++ W.data
                        ~flags:Flags.(default_flags |> set_end_stream)
                        (Cstruct.of_string "data"));
             ]
             [ !!W.(goaway NoError); ??eof ]);
      ]
  in

  let connection_functionalities : test_group =
    let ping_payload = "12345678" in
    test_group "Connection-level functionalities"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Servers sends a PING frame"
          (conn_only
          @ [ !!(W.ping ping_payload); ??(ping_p ping_payload) ]
          @ grace_end);
      ]
  in

  let stream_states_idle : test_group =
    test_group "Stream states - Idle"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Server sends DATA frame on idle stream"
          (conn_only
          @ [ !!W.(data Cstruct.empty); ??(goaway_code ProtocolError); ??eof ]);
        test "Server sends RST_STREAM frame"
          (conn_only
          @ [ !!W.(rst_stream NoError); ??(goaway_code ProtocolError); ??eof ]);
        test "Server sends WINDOW_UPDATE frame"
          (conn_only
          @ [
              !!W.(window_update ~id:1l 1024l);
              ??(goaway_code ProtocolError);
              ??eof;
            ]);
        test "Server sends HEADERS frame"
          (conn_only
          @ [
              !!W.(headers ~id:1l (`List []));
              ??(goaway_code ProtocolError);
              ??eof;
            ]);
      ]
  in

  let stream_states_half_closed_local : test_group =
    let stream_init =
      [
        ??(frame_header ~flags:Flags.(default_flags |> set_end_header) Headers);
        !!W.(
            headers
              ~flags:Flags.(default_flags |> set_end_header |> set_end_stream)
              (`List [ (":status", "200") ]));
      ]
    in

    let with_setup stream_nodes continuation_nodes =
      with_preface (stream_init @ stream_nodes) continuation_nodes
    in
    test_group
      ~ignore:Ignore.(frame_type WindowUpdate)
      ~streams:[ POST ("/", 0) ]
      "Stream states - Half-closed (local)"
      [
        test "Server sends RST_STREAM frame"
          (with_setup
             [ !!W.(rst_stream NoError) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends WINDOW_UPDATE frame"
          (with_setup
             [ !!W.(window_update ~id:1l 1024l ++ rst_stream NoError) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends DATA frame"
          (with_setup
             [
               !!W.(data (Cstruct.of_string "1234"));
               ??(stream_error 1l StreamClosed);
             ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends HEADERS frame"
          (with_setup
             [ !!W.(headers (`List [])); ??(stream_error 1l StreamClosed) ]
             [ !!W.(goaway NoError); ??eof ]);
      ]
  in

  let stream_states_half_closed_remote : test_group =
    let stream_init =
      [
        ??(frame_header
             ~flags:Flags.(default_flags |> set_end_header |> set_end_stream)
             Headers);
        !!W.(
            headers
              ~flags:Flags.(default_flags |> set_end_header)
              (`List [ (":status", "200") ]));
      ]
    in

    let with_setup stream_nodes continuation_nodes =
      with_preface (stream_init @ stream_nodes) continuation_nodes
    in

    test_group ~streams:[ GET "/" ] "Stream states - Half-closed (remote)"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Server sends RST_STREAM frame"
          (with_setup
             [ !!W.(rst_stream NoError) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends WINDOW_UPDATE frame"
          (with_setup
             [ !!W.(window_update ~id:1l 1024l ++ rst_stream NoError) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends DATA frame"
          (with_setup
             [ !!W.(data (Cstruct.of_string "1234") ++ rst_stream NoError) ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends DATA frame with END_STREAM flag set"
          (with_setup
             [
               !!W.(
                   data
                     ~flags:Flags.(default_flags |> set_end_stream)
                     (Cstruct.of_string "1234"));
             ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends HEADERS frame with END_STREAM flag set"
          (with_setup
             [
               !!W.(
                   headers
                     ~flags:
                       Flags.(default_flags |> set_end_header |> set_end_stream)
                     (`List []));
             ]
             [ !!W.(goaway NoError); ??eof ]);
      ]
  in

  let stream_states_closed : test_group =
    let stream_init =
      [
        ??(frame_header
             ~flags:Flags.(default_flags |> set_end_header |> set_end_stream)
             Headers);
        !!W.(
            headers
              ~flags:Flags.(default_flags |> set_end_header |> set_end_stream)
              (`List [ (":status", "200") ]));
      ]
    in

    let with_setup stream_nodes continuation_nodes =
      with_preface (stream_init @ stream_nodes) continuation_nodes
    in

    test_group ~streams:[ GET "/" ] "Stream states - Closed"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Server sends DATA frame"
          (with_setup
             [ !!W.(data (Cstruct.of_string "1234")) ]
             [ ??(goaway_code StreamClosed); ??eof ]);
        test "Server sends HEADERS frame"
          (with_setup
             [ !!W.(headers (`List [])) ]
             [ ??(goaway_code StreamClosed); ??eof ]);
        test "Server sends WINDOW_UPDATE frame"
          (with_setup
             [
               !!W.(window_update ~id:1l 1024l);
               ??(stream_error 1l StreamClosed);
             ]
             [ !!W.(goaway NoError); ??eof ]);
        test "Server sends RST_STREAM frame"
          (with_setup
             [ !!W.(rst_stream NoError); ??(stream_error 1l StreamClosed) ]
             [ !!W.(goaway NoError); ??eof ]);
      ]
  in

  let messages : test_group =
    let malformed = ??(stream_error 1l ProtocolError) in
    let with_setup malformed_setup continuation_nodes =
      with_preface
        (malformed_setup
        @ [
            ??(frame_header Headers
                 ~flags:
                   Flags.(default_flags |> set_end_header |> set_end_stream));
            malformed;
          ])
        continuation_nodes
    in

    test_group ~streams:[ GET "/" ] "Message exchange - responses"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "Server sends HEADERS frame without \":status\" pseudo-header"
          (with_setup [ !!W.(headers (`List [])) ] grace_end);
        test
          "Server sends HEADERS frame with duplicate \":status\" pseudo-header"
          (with_setup
             [
               !!W.(headers (`List [ (":status", "200"); (":status", "200") ]));
             ]
             grace_end);
        test "Server sends HEADERS frame with request pseudo-header"
          (with_setup
             [
               !!W.(
                   headers
                     ~flags:Flags.(default_flags |> set_end_header)
                     (`List [ (":path", "/"); (":method", "POST") ]));
             ]
             grace_end);
        test "Server sends HEADERS frame with unknown pseudo-header"
          (with_setup [ !!W.(headers (`List [ (":hello", "200") ])) ] grace_end);
        test
          "Server sends second HEADERS (trailers) with END_HEADER flag but \
           without END_STREAM flag"
          (with_setup
             [
               !!W.(
                   headers
                     ~flags:Flags.(default_flags |> set_end_header)
                     (`List [ (":status", "200") ])
                   ++ W.headers
                        ~flags:Flags.(default_flags |> set_end_header)
                        (`List []));
             ]
             grace_end);
        test
          "Server sends second HEADERS (trailers) with \":status\" \
           pseudo-header"
          (with_setup
             [
               !!W.(
                   headers
                     ~flags:Flags.(default_flags |> set_end_header)
                     (`List [ (":status", "200") ])
                   ++ W.headers
                        ~flags:
                          Flags.(
                            default_flags |> set_end_header |> set_end_stream)
                        (`List [ (":status", "200") ]));
             ]
             grace_end);
        test "Server sends second HEADERS (trailers) with unknown pseudo-header"
          (with_setup
             [
               !!W.(
                   headers
                     ~flags:Flags.(default_flags |> set_end_header)
                     (`List [ (":status", "200") ])
                   ++ W.headers
                        ~flags:
                          Flags.(
                            default_flags |> set_end_header |> set_end_stream)
                        (`List [ (":hello", "200") ]));
             ]
             grace_end);
      ]
  in

  let settings_impact : test_group =
    test_group "Settings impact"
      ~ignore:Ignore.(frame_type WindowUpdate)
      [
        test "MAX_CONCURRENT_STREAMS"
          ~streams:[ GET "/"; GET "/"; GET "/" ]
          begin
            with_preface
              ~settings:[ MaxConcurrentStreams 2l ]
              [ ??headers; ??headers ]
              [
                ??timeout;
                !!W.(settings [ MaxConcurrentStreams 3l ]);
                ??settings_ack;
                ??headers;
                !!W.(rst_stream ~id:1l NoError);
                !!W.(rst_stream ~id:3l NoError);
                !!W.(rst_stream ~id:5l NoError);
              ]
            @ grace_end
          end;
        test "INITIAL_WINDOW_SIZE"
          ~streams:[ POST ("/", 20_000) ]
          begin
            with_preface
              ~settings:[ InitialWindowSize 19_000l ]
              [
                ??headers;
                ??:data (fun css ->
                    let len = Cstruct.lenv css in
                    if len = 19_000 then `Done
                    else if len < 19_000 then `More
                    else
                      `NoMatch
                        (Format.asprintf
                           "exactly 19000 bytes of data in DATA frames, but \
                            got %i"
                           len));
                !!W.(settings [ InitialWindowSize 20_000l ]);
                ??settings_ack;
                ??:data (fun css ->
                    let len = Cstruct.lenv css in
                    if len = 1_000 then `Done
                    else if len < 1_000 then `More
                    else
                      `NoMatch
                        (Format.asprintf
                           "1000 bytes of data in DATA frames, but got %i" len));
              ]
              [ !!W.(rst_stream ~id:1l NoError) ]
            @ grace_end
          end;
        test "MAX_FRAME_SIZE"
          ~streams:[ POST ("/", 50_000) ]
          begin
            with_preface ~settings:[ MaxFrameSize 20_000 ]
              [
                ??headers;
                ??:data (fun css ->
                    if List.for_all (fun cs -> Cstruct.length cs < 20_000) css
                    then
                      `NoMatch
                        "DATA frames with payload size no higher than 20000"
                    else if Cstruct.lenv css = 50_000 then `Done
                    else `More);
              ]
              [ !!W.(rst_stream ~id:1l NoError) ]
            @ grace_end
          end;
      ]
  in

  Runner.run_groups ~sw ~net ~clock first_port
    [
      connection_preface;
      frame_header_validation;
      connection_frames_validation;
      stream_frames_validation;
      connection_functionalities;
      stream_states_idle;
      stream_states_half_closed_local;
      stream_states_half_closed_remote;
      stream_states_closed;
      messages;
      settings_impact;
    ]
