connection frames: settings, ping, window_size, goaway
stream frames: headers, data, rst_stream, push_promise, window_size, continuation

What should client do:
1. Initialize HTTP/2 connection on port 8000
2. Sends a GET (no-body) request with END_STREAM flag to any path

## Test groups:

### 1. Connection preface
- [x] Initialization, standard preface exchange.
- [x] Server sends invalid preface.
    Server sends a PING frame instead of SETTINGS. Expects client to send GOAWAY from with PROTOCOL_ERROR code.
- [x] Server acknowledges client's SETTINGS before its praface.
    Server sends a SETTINGS frame with ACK flag immiedietly after received SETTINGS from client's preface. Expects client to send GOAWAY frame with PROTOCOL_ERROR code.

### 2. Validating frame header
- [ ] Server sends a frame with invalid payload size.
    Server sends a frame with payload size value in the header smaller than the minimum frame size (2^14).
- [ ] Server sends a frame with invalid payload size.
    Server sends a frame with payload size value in the header larger than the MAX_FRAME_SIZE setting.
- [x] Server sends a frame with unknown frame type
    Client should ignore the frame

### 3. Parsing and validating connection-level frames
- [x] Server sends a SETTINGS frame with ACK flag with payload length > 0
    Client should respond with a connection error of type FRAME_SIZE_ERROR
- [x] Server sends a SETTINGS frame with stream id != 0
    Client should respond with a connection error of type PROTOCOL_ERROR
- [ ] Server sends a SETTINGS frame with payload_length other than a multiple of 6
    Client should respond with a connection error of type FRAME_SIZE_ERROR
- [x] Server sends a SETTINGS frame with one setting with an unknown identifier
    Client should apply the known-id settings and ignore the unknown one
- [x] Server sends a SETTINGS frame with custom, valid values: 

  `SETTINGS_HEADER_TABLE_SIZE: 5120`
  `SETTINGS_ENABLE_PUSH: 0`
  `SETTINGS_MAX_CONCURRENT_STREAMS: 2000`
  `SETTINGS_INITIAL_WINDOW_SIZE: 131070`
  `SETTINGS_MAX_FRAME_SIZE: 163840`
  `SETTINGS_MAX_HEADER_LIST_SIZE: 1000`

   SETTINGS should be accepted

- [x] Server sends a SETTINGS frame with PUSH_PROMISE setting set to value > 1
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a SETTINGS frame with PUSH_PROMISE setting set to value 1
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a SETTINGS frame with INITIAL_WINDOW_SIZE setting set to value > 2^31-1
    Client should respond with a connection error of type FLOW_CONTROL_ERROR
- [x] Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set to value < 16384
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a SETTINGS frame with MAX_FRAME_SIZE setting set to value > 2^24-1
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a PING frame with stream id != 0
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a PING frame with payload length != 8
    Client should respond with a connection error of type FRAME_SIZE_ERROR
- [x] Server sends a GOAWAY frame with stream id != 0 
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a GOAWAY frame with unknown error code
    Client should accpet the frame, treat it as PROTOCOL_ERROR code and close the TCP connection normally
- [x] Server sends a WINDOW_UPDATE frame with a valid window size increment value and stream id = 0
    Client accepts the frame
- [x] Server sends a WINDOW_UPDATE frame with payload length != 5
    Client should respond with a connection error of type FRAME_SIZE_ERROR
- [x] Server sends a WINDOW_UPDATE frame with window size increment value = 0 and stream id = 0
    Client should respond with a connection error of type PROTOCOL_ERROR

### 4. Parsing and validating stream-level frames
- [x] Server responds with a final 200 code HEADERS frame with END_STREAM flag
    Client accepts the frame
- [x] Server responds with a HEADERS frame with stream id = 0
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server responds with a HEADERS frame with padding length > payload length
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server responds with a HEADERS frame with invalid headers block
    Client should respond with a connection error of type COMPRESSION_ERROR
- [ ] Server responds with a headers divided into HEADERS frame and CONTINUATION frames
    Client should accept the frames
- [ ] Server sends a PING frame between HEADERS and CONTINUATION frames
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a WINDOW_UPDATE frame before responding with HEADERS
    Client accepts the frames
- [x] Server sends a RST_STREAM frame
    Client accepts the frame and closes the stream
- [x] Server sends a RST_STREAM with stream id = 0
    Client should respond with a connection error of type PROTOCOL_ERROR
- [x] Server sends a RST_STREAM with payload length != 4
    Client should respond with a connection error of type FRAME_SIZE_ERROR

### 5. Connection-level functionalities
- [ ] Servers sends a PING frame
    Client responds with PING frame with ACK flag and the same payload

