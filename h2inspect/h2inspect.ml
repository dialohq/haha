open Runner
open H2kit

let run_server_tests ~sw clock net =
  Eio.Fiber.fork ~sw @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let preface : Runner.test_group =
    {
      label = "Connection preface";
      tests =
        [
          {
            label = "Initialization, standard preface exchange";
            description =
              Some
                {|[Section 3.4. of RFC9113] "In HTTP/2, each endpoint is required to send a connection preface as a final confirmation of the protocol in use and to establish th initial settings for the HTTP/2 connection."|};
            runner =
              S.conn_only >> E.magic >> E.settings >> W.settings []
              >> W.settings_ack >> E.settings_ack >> W.goaway NoError >> E.eof;
          };
          {
            label = "Server sends invalid connection preface";
            description =
              Some
                {|[Section 3.4 of RFC9113] "The server connection preface consists of a potentially empty SETTINGS frame (Section 6.5) that MUST be @{<ul>the first frame the server sends@} in the HTTP/2 connection. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings >> W.ping >> E.goaway
              >> E.eof;
          };
          {
            label =
              "Server acknowledges client's SETTINGS before sending its preface";
            description =
              Some
                {|[Section 3.4. of RFC9113] "The SETTINGS frames received from a peer as part of the connection preface MUST be acknowledged (see Section 6.5.3) @{<ul>after@} sending the connection preface. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings >> W.settings_ack >> E.goaway
              >> E.eof;
          };
        ];
    }
  in

  let frame_header_validation : Runner.test_group =
    {
      label = "Frame header validation";
      tests =
        [
          {
            label = "Server sends a frame with unknown frame type";
            description =
              Some
                {|[Section 4.1. of RFC9113] "Type: The 8-bit type of the frame. The frame type determines the format and semantics of the frame. Frames defined in this document are listed in Section 6. Implementations MUST @{<ul>ignore and discard@} frames of unknown types."|};
            runner =
              S.conn_only >> E.magic >> E.settings >> W.settings [] >> W.unknown
              >> W.settings_ack >> E.settings_ack >> W.goaway NoError >> E.eof;
          };
        ];
    }
  in

  let connection_frames_validation : Runner.test_group =
    {
      label = "Parsing and validating connection-level frames";
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
              S.conn_only >> S.preface
              >> W.custom_header_settings
                   ~flags:Flags.(default_flags |> set_ack)
                   ()
              >> E.conn_error FrameSizeError
              >> E.eof;
          };
          {
            label = "Server sends a SETTINGS frame with stream id != 0";
            description =
              Some
                {|[Section 6.5. pf RFC9113] "SETTINGS frames always apply to a connection, never a single stream. The @{<ul>stream identifier@} for a SETTINGS frame @{<ul>MUST be zero (0x00)@}. If an endpoint receives a SETTINGS frame whose Stream Identifier field is anything other than 0x00, the endpoint MUST respond with a connection error (Section 5.4.1) of type @{<ul>PROTOCOL_ERROR@}."|};
            runner =
              S.conn_only >> S.preface
              >> W.custom_header_settings ~id:1l ()
              >> E.conn_error ProtocolError >> E.eof;
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
              S.conn_only >> E.magic >> E.settings >> W.unknown_setting
              >> W.settings_ack >> E.settings_ack >> W.goaway NoError >> E.eof;
          };
          {
            label = "Server sends a SETTINGS frame with custom, valid values";
            description = None;
            runner =
              S.conn_only >> E.magic >> E.settings
              >> W.settings
                   [
                     HeaderTableSize 5120;
                     EnablePush 0;
                     MaxConcurrentStreams 2000l;
                     InitialWindowSize 131_070l;
                     MaxFrameSize 163_840;
                     MaxHeaderListSize 1000;
                   ]
              >> W.settings_ack >> E.settings_ack >> W.goaway NoError >> E.eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with PUSH_PROMISE setting set to \
               value > 1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_ENABLE_PUSH (0x02): [...] Any value other than 0 or 1 MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings
              >> W.settings [ EnablePush 2 ]
              >> W.settings_ack >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with PUSH_PROMISE setting set to \
               value 1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_ENABLE_PUSH (0x02): [...] A server MUST NOT explicitly set this value to 1. [...] A client MUST treat receipt of a SETTINGS frame with SETTINGS_ENABLE_PUSH set to 1 as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings
              >> W.settings [ EnablePush 1 ]
              >> W.settings_ack >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with INITIAL_WINDOW_SIZE setting \
               set to value > 2^31-1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_INITIAL_WINDOW_SIZE (0x04): [...] Values above the maximum flow-control window size of 2^31-1 MUST be treated as a connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings
              >> W.settings [ InitialWindowSize (Int32.add 2_147_483_647l 1l) ]
              >> W.settings_ack
              >> E.conn_error FlowControlError
              >> E.eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set \
               to value < 16384";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_MAX_FRAME_SIZE (0x05): [...] The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (224-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings
              >> W.settings [ MaxFrameSize 16_383 ]
              >> W.settings_ack >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label =
              "Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set \
               to value > 2^24-1";
            description =
              Some
                {|[Section 6.5.2.] "SETTINGS_MAX_FRAME_SIZE (0x05): [...] The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (2^24-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
            runner =
              S.conn_only >> E.magic >> E.settings
              >> W.settings [ MaxFrameSize 16_777_215 ]
              >> W.settings_ack >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label = "Server sends a PING frame with stream id != 0";
            description = None;
            runner =
              S.conn_only >> S.preface
              >> W.custom_header_ping ~id:1l ()
              >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label = "Server sends a PING frame with payload length != 8";
            description = None;
            runner =
              S.conn_only >> S.preface
              >> W.custom_header_ping ~len:5 ()
              >> E.conn_error FrameSizeError
              >> E.eof;
          };
          {
            label = "Server sends a GOAWAY frame with stream id != 0";
            description = None;
            runner =
              S.conn_only >> S.preface
              >> W.custom_header_goaway ~id:1l ()
              >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label = "Server sends a GOAWAY frame with unknown error code";
            description = None;
            runner =
              S.conn_only >> S.preface
              >> W.goaway (UnknownError_code 20l)
              >> E.eof;
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame with a valid window size \
               increment value and stream id = 0";
            description = None;
            runner =
              S.conn_only >> S.preface >> W.window_update 1024l
              >> W.goaway NoError >> E.eof;
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame with payload length != 4";
            description = None;
            runner =
              S.conn_only >> S.preface
              >> W.window_update ~len:3 1024l
              >> E.conn_error FrameSizeError
              >> E.eof;
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame with window size increment \
               value = 0 and stream id = 0";
            description = None;
            runner =
              S.conn_only >> S.preface >> W.window_update ~id:0l 0l
              >> E.conn_error ProtocolError >> E.eof;
          };
        ];
    }
  in

  let stream_frames_validation : Runner.test_group =
    {
      label = "Parsing and validating stream-level frames";
      tests =
        [
          {
            label =
              "Server responds with a final 200 code HEADERS frame with \
               END_STREAM flag";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.headers (`List [ (":status", "200") ])
              >> W.goaway NoError >> E.eof;
          };
          {
            label = "Server responds with a HEADERS frame with stream id = 0";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.headers ~id:0l (`List [ (":status", "200") ])
              >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label =
              "Server responds with a HEADERS frame with padding length > \
               payload length";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.headers
                   ~flags:
                     Flags.(
                       default_flags |> set_end_header |> set_end_stream
                       |> set_padded)
                   ~pad_len:50
                   (`List [ (":status", "200") ])
              >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label =
              "Server responds with a HEADERS frame with invalid headers block";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.headers (`Block (Cstruct.of_hex "400A686561646572"))
              >> E.conn_error CompressionError
              >> E.eof;
          };
          {
            label =
              "Server sends a WINDOW_UPDATE frame before responding with \
               HEADERS";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.window_update ~id:1l 1024l
              >> W.headers (`List [ (":status", "200") ])
              >> W.goaway NoError >> E.eof;
          };
          {
            label = "Server sends a RST_STREAM frame";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers >> W.rst_stream NoError
              >> W.goaway NoError >> E.eof;
          };
          {
            label = "Server sends a RST_STREAM with stream id = 0";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.rst_stream ~id:0l NoError
              >> E.conn_error ProtocolError >> E.eof;
          };
          {
            label = "Server sends a RST_STREAM with payload length != 4";
            description = None;
            runner =
              I.window_update >> S.preface >> E.headers
              >> W.rst_stream ~len:3 NoError
              >> E.conn_error FrameSizeError
              >> E.eof;
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
    ]
  in
  Runner.run_groups ~sw ~net ~clock groups
