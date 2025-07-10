open Runner
open H2kit
module W = Writer
module Serializers = Serializers.Make (Buf_write)
module Case = Case

let run_server_tests ?(first_port = 8050) ~sw clock net =
  let preface : test_group =
    {
      label = "Connection preface";
      assume = [];
      tests =
        [
          {
            label = "Initialization, standard preface exchange";
            description =
              Some
                {|[Section 3.4. of RFC9113] "In HTTP/2, each endpoint is required to send a connection preface as a final confirmation of the protocol in use and to establish th initial settings for the HTTP/2 connection."|};
            runner =
              S.preface
              *> register_ignore
                   Ignore.(stream_frames + frame_type WindowUpdate)
              *> (W.goaway NoError +> eof);
          };
          {
            label = "Server sends invalid connection preface";
            description =
              Some
                {|[Section 3.4 of RFC9113] "The server connection preface consists of a potentially empty SETTINGS frame (Section 6.5) that MUST be @{<ul>the first frame the server sends@} in the HTTP/2 connection. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              register_ignore Ignore.(stream_frames + frame_type WindowUpdate)
              *> magic *> settings
              *> (W.ping "12345678" +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server acknowledges client's SETTINGS before sending its preface";
            description =
              Some
                {|[Section 3.4. of RFC9113] "The SETTINGS frames received from a peer as part of the connection preface MUST be acknowledged (see Section 6.5.3) @{<ul>after@} sending the connection preface. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              register_ignore Ignore.(stream_frames + frame_type WindowUpdate)
              *> magic *> settings
              *> (W.settings ~flags:Flags.(default_flags |> set_ack) []
                 +> conn_error ProtocolError);
          };
        ];
    }
  in

  let frame_header_validation : test_group =
    {
      label = "Frame header validation";
      assume = [];
      tests =
        [
          {
            label = "Server sends a frame with unknown frame type";
            description =
              Some
                {|[Section 4.1. of RFC9113] "Type: The 8-bit type of the frame. The frame type determines the format and semantics of the frame. Frames defined in this document are listed in Section 6. Implementations MUST @{<ul>ignore and discard@} frames of unknown types."|};
            runner =
              ( register_ignore Ignore.(stream_frames + frame_type WindowUpdate)
              *> magic *> settings
              *> (W.settings [] ++ W.unknown
                 ++ W.settings ~flags:Flags.(default_flags |> set_ack) []
                 ++ W.goaway NoError +> frame_header)
              >>= function
                | { frame_type = Settings; flags; _ } when Flags.test_ack flags
                  ->
                    return ()
                | _ -> fail "Expected SETTINGS with ACK flag set" *> eof );
          };
        ];
    }
  in

  let connection_frames_validation : test_group =
    {
      label = "Parsing and validating connection-level frames";
      assume = [];
      tests =
        [
          {
            label =
              "Server sends a SETTINGS frame with ACK flag and payload length \
               > 0";
            description =
              Some
                {|ACK (0x01): "[...] Receipt of a SETTINGS frame with the ACK flag set and a length field value other than 0 MUST be treated as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR."|};
            runner =
              S.conn_only
              *> (W.settings
                    ~flags:Flags.(default_flags |> set_ack)
                    [ EnablePush 0 ]
                 +> conn_error FrameSizeError)
              *> eof;
          };
          {
            label = "Server sends a SETTINGS frame with stream id != 0";
            description =
              Some
                {|[Section 6.5. pf RFC9113] "SETTINGS frames always apply to a connection, never a single stream. The @{<ul>stream identifier@} for a SETTINGS frame @{<ul>MUST be zero (0x00)@}. If an endpoint receives a SETTINGS frame whose Stream Identifier field is anything other than 0x00, the endpoint MUST respond with a connection error (Section 5.4.1) of type @{<ul>PROTOCOL_ERROR@}."|};
            runner =
              S.conn_only
              *> (W.settings ~id:1l [] +> conn_error ProtocolError)
              *> eof;
          };
          (*{
            label =
              "Server sends a SETTINGS frame with payload length other than a \
               multiple of 6";
            description = None;
            runner =
              S.conn_only >> S.preface
              >> W.custom_header_settings ~len:7 ()
              >> E.conn_error FrameSizeError;
          };*)
          {
            label =
              "Server sends a SETTINGS frame with one setting with an unknown \
               identifier";
            description =
              Some
                {|[Section 6.5.2. of RFC9113] "An endpoint that receives a SETTINGS frame with any unknown or unsupported identifier MUST @{<ul>ignore@} that setting."|};
            runner =
              S.conn_only
              *> (W.unknown_setting +> settings_ack)
              *> (W.goaway NoError +> eof);
          };
          {
            label = "Server sends a SETTINGS frame with custom, valid values";
            description = None;
            runner =
              S.conn_only
              *> (W.settings
                    [
                      HeaderTableSize 5120;
                      EnablePush 0;
                      MaxConcurrentStreams 2000l;
                      InitialWindowSize 131_070l;
                      MaxFrameSize 163_840;
                      MaxHeaderListSize 1000;
                    ]
                 +> settings_ack)
              *> (W.goaway NoError +> eof);
          };
          {
            label =
              "Server sends a SETTINGS frame with PUSH_PROMISE setting set to \
               value > 1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_ENABLE_PUSH (0x02): [...] Any value other than 0 or 1 MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only
              *> (W.settings [ EnablePush 2 ] +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with PUSH_PROMISE setting set to \
               value 1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_ENABLE_PUSH (0x02): [...] A server MUST NOT explicitly set this value to 1. [...] A client MUST treat receipt of a SETTINGS frame with SETTINGS_ENABLE_PUSH set to 1 as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only
              *> (W.settings [ EnablePush 1 ] +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with INITIAL_WINDOW_SIZE setting \
               set to value > 2^31-1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_INITIAL_WINDOW_SIZE (0x04): [...] Values above the maximum flow-control window size of 2^31-1 MUST be treated as a connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR."|};
            runner =
              S.conn_only
              *> (W.settings [ InitialWindowSize (Int32.add 2_147_483_647l 1l) ]
                 +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set \
               to value < 16384";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_MAX_FRAME_SIZE (0x05): [...] The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (224-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only
              *> (W.settings [ MaxFrameSize 16_383 ] +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set \
               to value > 2^24-1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_MAX_FRAME_SIZE (0x05): [...] The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (2^24-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only
              *> (W.settings [ MaxFrameSize 16_777_215 ]
                 +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends a PING frame with stream id != 0";
            description = None;
            runner =
              S.conn_only
              *> (W.ping ~id:1l "12345678" +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends a PING frame with payload length != 8";
            description = None;
            runner =
              S.conn_only
              *> (W.ping ~len:5 "12345678" +> conn_error FrameSizeError)
              *> eof;
          };
          {
            label = "Server sends a GOAWAY frame with stream id != 0";
            description = None;
            runner =
              S.conn_only
              *> (W.goaway ~id:1l NoError +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends a GOAWAY frame with unknown error code";
            description = None;
            runner = S.conn_only *> (W.goaway (UnknownError_code 20l) +> eof);
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame with a valid window size \
               increment value and stream id = 0";
            description = None;
            runner =
              S.conn_only *> (W.window_update 1024l ++ W.goaway NoError +> eof);
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame with payload length != 4";
            description = None;
            runner =
              S.conn_only
              *> (W.window_update ~len:3 1024l +> conn_error FrameSizeError)
              *> eof;
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame with window size increment \
               value = 0 and stream id = 0";
            description = None;
            runner =
              S.conn_only
              *> (W.window_update ~id:0l 0l +> conn_error ProtocolError)
              *> eof;
          };
        ];
    }
  in

  let stream_frames_validation : test_group =
    let start =
      register_ignore I.(frame_type WindowUpdate) *> S.preface *> headers
    in
    {
      label = "Parsing and validating stream-level frames";
      assume = [ GET "/" ];
      tests =
        [
          {
            label =
              "Server responds with a final 200 code HEADERS frame with \
               END_STREAM flag";
            description = None;
            runner =
              start
              *> (W.headers (`List [ (":status", "200") ])
                 ++ W.goaway NoError +> eof);
          };
          {
            label = "Server responds with a HEADERS frame with stream id = 0";
            description = None;
            runner =
              start
              *> (W.headers ~id:0l (`List [ (":status", "200") ])
                 +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server responds with a HEADERS frame with padding length > \
               payload length";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:
                      Flags.(
                        default_flags |> set_end_header |> set_end_stream
                        |> set_padded)
                    ~pad_len:50
                    (`List [ (":status", "200") ])
                 +> conn_error ProtocolError)
              *> eof;
          };
          {
            label =
              "Server responds with a HEADERS frame with invalid headers block";
            description = None;
            runner =
              start
              *> (W.headers (`Block (Cstruct.of_hex "400A686561646572"))
                 +> conn_error CompressionError)
              *> eof;
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame before responding with \
               HEADERS";
            description = None;
            runner =
              start
              *> (W.window_update ~id:1l 1024l
                 ++ W.headers (`List [ (":status", "200") ])
                 ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends a RST_STREAM frame";
            description = None;
            runner = start *> (W.rst_stream NoError ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends a RST_STREAM with stream id = 0";
            description = None;
            runner =
              start
              *> (W.rst_stream ~id:0l NoError +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends a RST_STREAM with payload length != 4";
            description = None;
            runner =
              start
              *> (W.rst_stream ~len:3 NoError +> conn_error FrameSizeError)
              *> eof;
          };
          {
            label = "Server sends a DATA frame";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:Flags.(default_flags |> set_end_header)
                    (`List [ (":status", "200") ])
                 ++ W.data
                      ~flags:Flags.(default_flags |> set_end_stream)
                      (Cstruct.of_string "data")
                 ++ W.goaway NoError +> eof);
          };
        ];
    }
  in

  let connection_functionalities : test_group =
    let ping_payload = "12345678" in
    {
      label = "Connection-level functionalities";
      assume = [];
      tests =
        [
          {
            label = "Servers sends a PING frame";
            description = None;
            runner =
              S.conn_only
              *> ( W.ping ping_payload +> ping >>= function
                   | cs when cs = Cstruct.of_string ping_payload -> return ()
                   | _ -> fail "Expected PING with payload \"12345678\"" )
              *> (W.goaway NoError +> eof);
          };
        ];
    }
  in

  let stream_states_idle : test_group =
    {
      label = "Stream states - Idle";
      assume = [];
      tests =
        [
          {
            label = "Server sends DATA frame on idle stream";
            description = None;
            runner =
              register_ignore I.(frame_type WindowUpdate)
              *> S.preface
              *> (W.data Cstruct.empty +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends RST_STREAM frame";
            description = None;
            runner =
              register_ignore I.(frame_type WindowUpdate)
              *> S.preface
              *> (W.rst_stream NoError +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends WINDOW_UPDATE frame";
            description = None;
            runner =
              register_ignore I.(frame_type WindowUpdate)
              *> S.preface
              *> (W.window_update ~id:1l 1024l +> conn_error ProtocolError)
              *> eof;
          };
          {
            label = "Server sends HEADERS frame";
            description = None;
            runner =
              register_ignore I.(frame_type WindowUpdate)
              *> S.preface
              *> (W.headers ~id:1l (`List []) +> conn_error ProtocolError)
              *> eof;
          };
        ];
    }
  in

  let stream_states_half_closed_local : test_group =
    let start =
      register_ignore I.(frame_type WindowUpdate)
      *> S.preface
      *> (frame_header
         >>= ( function
         | { frame_type = Headers; flags; _ }
           when Flags.test_end_header flags && not (Flags.test_end_stream flags)
           ->
             return ()
         | _ -> fail "Expected HEADERS with only END_HEADER flag set" )
         <+ W.headers
              ~flags:Flags.(default_flags |> set_end_header |> set_end_stream)
              (`List [ (":status", "200") ]))
    in
    {
      label = "Stream states - Half-closed (local)";
      assume = [ POST "/" ];
      tests =
        [
          {
            label = "Server sends RST_STREAM frame";
            description = None;
            runner = start *> (W.rst_stream NoError ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends WINDOW_UPDATE frame";
            description = None;
            runner =
              start
              *> (W.window_update ~id:1l 1024l
                 ++ W.rst_stream NoError ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends DATA frame";
            description = None;
            runner =
              start
              *> (W.data (Cstruct.of_string "1234")
                 +> stream_error 1l StreamClosed)
              *> (W.goaway NoError +> eof);
          };
          {
            label = "Server sends HEADERS frame";
            description = None;
            runner =
              start
              *> (W.headers (`List []) +> stream_error 1l StreamClosed)
              *> (W.goaway NoError +> eof);
          };
        ];
    }
  in

  let stream_states_half_closed_remote : test_group =
    let start =
      register_ignore I.(frame_type WindowUpdate)
      *> S.preface
      *> (frame_header
         >>= ( function
         | { frame_type = Headers; flags; _ }
           when Flags.test_end_header flags && Flags.test_end_stream flags ->
             return ()
         | _ -> fail "Expected HEADERS with END_HEADER and END_STREAM flags set" )
         <+ W.headers
              ~flags:Flags.(default_flags |> set_end_header)
              (`List [ (":status", "200") ]))
    in
    {
      label = "Stream states - Half-closed (remote)";
      assume = [ GET "/" ];
      tests =
        [
          {
            label = "Server sends RST_STREAM frame";
            description = None;
            runner = start *> (W.rst_stream NoError ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends WINDOW_UPDATE frame";
            description = None;
            runner =
              start
              *> (W.window_update ~id:1l 1024l
                 ++ W.rst_stream NoError ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends DATA frame";
            description = None;
            runner =
              start
              *> (W.data (Cstruct.of_string "1234")
                 ++ W.rst_stream NoError ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends DATA frame with END_STREAM flag set";
            description = None;
            runner =
              start
              *> (W.data
                    ~flags:Flags.(default_flags |> set_end_stream)
                    (Cstruct.of_string "1234")
                 ++ W.goaway NoError +> eof);
          };
          {
            label = "Server sends HEADERS frame with END_STREAM flag set";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:
                      Flags.(default_flags |> set_end_header |> set_end_stream)
                    (`List [])
                 ++ W.goaway NoError +> eof);
          };
        ];
    }
  in

  let stream_states_closed : test_group =
    let start =
      register_ignore I.(frame_type WindowUpdate)
      *> S.preface
      *> (frame_header
         >>= ( function
         | { frame_type = Headers; flags; _ }
           when Flags.test_end_header flags && Flags.test_end_stream flags ->
             return ()
         | _ -> fail "Expected HEADERS with END_HEADER and END_STREAM flags set" )
         <+ W.headers
              ~flags:Flags.(default_flags |> set_end_header |> set_end_stream)
              (`List [ (":status", "200") ]))
    in
    {
      label = "Stream states - Closed";
      assume = [ GET "/" ];
      tests =
        [
          {
            label = "Server sends DATA frame";
            description = None;
            runner =
              start
              *> (W.data (Cstruct.of_string "1234") +> conn_error StreamClosed)
              *> eof;
          };
          {
            label = "Server sends HEADERS frame";
            description = None;
            runner =
              start *> (W.headers (`List []) +> conn_error StreamClosed) *> eof;
          };
          {
            label = "Server sends WINDOW_UPDATE frame";
            description = None;
            runner =
              start
              *> (W.window_update ~id:1l 1024l +> stream_error 1l StreamClosed)
              *> (W.goaway NoError +> eof);
          };
          {
            label = "Server sends RST_STREAM frame";
            description = None;
            runner =
              start
              *> (W.rst_stream NoError +> stream_error 1l StreamClosed)
              *> (W.goaway NoError +> eof);
          };
        ];
    }
  in

  let messages : test_group =
    let start =
      register_ignore I.(frame_type WindowUpdate)
      *> S.preface
      *> ( frame_header >>= function
           | { frame_type = Headers; flags; _ }
             when Flags.test_end_header flags && Flags.test_end_stream flags ->
               return ()
           | _ ->
               fail "Expected HEADERS with END_HEADER and END_STREAM flags set"
         )
    in
    let malformed =
      stream_error 1l ProtocolError *> (W.goaway NoError +> eof)
    in
    {
      label = "Message exchange - responses";
      assume = [ GET "/" ];
      tests =
        [
          {
            label =
              "Server sends HEADERS frame without \":status\" pseudo-header";
            description = None;
            runner = start *> (W.headers (`List []) +> malformed);
          };
          {
            label =
              "Server sends HEADERS frame with duplicate \":status\" \
               pseudo-header";
            description = None;
            runner =
              start
              *> (W.headers (`List [ (":status", "200"); (":status", "200") ])
                 +> malformed);
          };
          {
            label = "Server sends HEADERS frame with request pseudo-header";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:Flags.(default_flags |> set_end_header)
                    (`List [ (":path", "/"); (":method", "POST") ])
                 +> malformed);
          };
          {
            label = "Server sends HEADERS frame with unknown pseudo-header";
            description = None;
            runner =
              start *> (W.headers (`List [ (":hello", "200") ]) +> malformed);
          };
          {
            label =
              "Server sends second HEADERS (trailers) with END_HEADER flag but \
               without END_STREAM flag";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:Flags.(default_flags |> set_end_header)
                    (`List [ (":status", "200") ])
                 ++ W.headers
                      ~flags:Flags.(default_flags |> set_end_header)
                      (`List [])
                 +> malformed);
          };
          {
            label =
              "Server sends second HEADERS (trailers) with \":status\" \
               pseudo-header";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:Flags.(default_flags |> set_end_header)
                    (`List [ (":status", "200") ])
                 ++ W.headers
                      ~flags:
                        Flags.(
                          default_flags |> set_end_header |> set_end_stream)
                      (`List [ (":status", "200") ])
                 +> malformed);
          };
          {
            label =
              "Server sends second HEADERS (trailers) with unknown \
               pseudo-header";
            description = None;
            runner =
              start
              *> (W.headers
                    ~flags:Flags.(default_flags |> set_end_header)
                    (`List [ (":status", "200") ])
                 ++ W.headers
                      ~flags:
                        Flags.(
                          default_flags |> set_end_header |> set_end_stream)
                      (`List [ (":hello", "200") ])
                 +> malformed);
          };
        ];
    }
  in

  let groups : Runner.test_group list =
    [
      preface;
      frame_header_validation;
      connection_frames_validation;
      stream_frames_validation;
      connection_functionalities;
      stream_states_idle;
      stream_states_half_closed_local;
      stream_states_half_closed_remote;
      stream_states_closed;
      messages;
    ]
  in
  Runner.run_groups ~sw ~net ~clock first_port (List.map (fun gr -> gr) groups)
