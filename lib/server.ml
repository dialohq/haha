(* type data = Streams.Stream.payload *)
(* type writer = Bigstringaf.t -> unit *)
(* module Reader = struct *)
(*   type t = data Eio.Stream.t *)
(*   let read t = Eio.Stream.take t *)
(* end *)
(* module Request = struct *)
(*   type t = { meth : Method.t; path : string; reader : Reader.t option } *)
(*   let meth t = t.meth *)
(*   let path t = t.path *)
(*   let reader t = t.reader *)
(* end *)
(* module Response = struct *)
(*   type t = { status : int; headers : string * string } *)
(*   let status t = t.status *)
(*   let headers t = t.headers *)
(* end *)
(* type connection = { *)
(*   (* request_handler : Request.t -> unit; *) *)
(*   (* error_handler : Error.t -> unit; *) *)
(*   connection_handler : *)
(*     'a. 'a Eio.Flow.two_way -> Eio.Net.Sockaddr.stream -> unit; *)
(* } *)
(* let respond _request _response = () *)
(* let respond_with_body _request _response _body = () *)
(* let open_stream _request _reponse = Obj.magic () *)

type settings_sync = Syncing of Settings.t | Idle

type state = {
  client_settings : Settings.t;
  server_settings : Settings.t;
  settings_status : settings_sync;
  streams : Streams.t;
  hpack_decoder : Hpack.Decoder.t;
  shutdown : bool;
  parse_state : Parse.parse_state;
}

type end_state = state * Error.connection_error

type step =
  | Next_state of (state, state * Error.stream_error) result
  | End_state of end_state

let initial_state recv_settings settings =
  {
    client_settings = Settings.(update_with_list default recv_settings);
    server_settings = Settings.default;
    settings_status = Syncing settings;
    streams = Streams.initial;
    hpack_decoder = Hpack.Decoder.create 1000;
    shutdown = false;
    parse_state = Magic;
  }

let write_rst_stream f stream_id code =
  Serialize.write_rst_stream_frame f stream_id code

let write_goaway f last_stream_id error_code debug_data =
  Serialize.write_go_away_frame f last_stream_id error_code debug_data

let write_ping f payload ~(ack : bool) =
  let frame_info =
    {
      Serialize.flags =
        (if ack then Flags.(set_ack default_flags) else Flags.default_flags);
      stream_id = Stream_identifier.connection;
    }
  in

  Serialize.write_ping_frame f frame_info payload

let write_settings f settings ~(ack : bool) () =
  let settings_list = Settings.to_settings_list settings in
  let frame_info =
    {
      Serialize.flags =
        (if ack then Flags.(set_ack default_flags) else Flags.default_flags);
      stream_id = Stream_identifier.connection;
    }
  in
  Serialize.write_settings_frame f frame_info settings_list;
  Printf.printf "Serialized settings\n%!"

let preface_handler (frame : Frame.t) (recv_settings : Settings.settings_list) =
  let { Frame.frame_header = { flags; _ }; _ } = frame in
  let state = initial_state recv_settings Settings.default in

  if Flags.test_ack flags then
    End_state
      ( state,
        ( Error_code.ProtocolError,
          "Unexpected ACK flag in preface client SETTINGS frame." ) )
  else
    (* write_settings f Settings.default ~ack:false (); *)
    (* write_settings f Settings.default ~ack:true (); *)
    (* Serialize.write_window_update_frame f Stream_identifier.connection *)
    (* Settings.WindowSize.initial_increment; *)
    (* wakeup_writer (); *)
    Next_state (Ok state)

let listen listen_socket env =
  let connection_handler socket addr =
    (match addr with
    | `Unix s -> Printf.printf "Starting connection for %s\n%!" s
    | `Tcp (ip, port) ->
        Format.printf "Starting connection for %a:%i@." Eio.Net.Ipaddr.pp ip
          port);
    let write_io () =
      Eio.Time.sleep env#clock 100000.;
      Cstruct.create 10
    in

    let frame_handler (frame : Parse.parse_result) (state : state) :
        state option =
      let next_step state = Some state in

      let connection_error _error_code _msg =
        (* TODO: handle connection error *)
        Some state
      in
      let stream_error _stream_id _code =
        (* TODO: handler stream error here *)
        Some state
      in

      match frame with
      | Magic_string ->
          Printf.printf "Received preface string\n%!";
          Some state
      | Frame
          {
            Frame.frame_payload = Data payload;
            frame_header = { flags; stream_id; _ };
            _;
          } -> (
          Printf.printf "kurcze blaszka!!!\n%!";
          let end_stream = Flags.test_end_stream flags in
          match Streams.state_of_id state.streams stream_id with
          | Idle | Half_closed Remote ->
              stream_error stream_id Error_code.StreamClosed
          | Reserved _ ->
              connection_error Error_code.ProtocolError
                "DATA frame received on reserved stream"
          | Closed ->
              connection_error Error_code.StreamClosed
                "DATA frame received on closed stream!"
          | Open recv_stream ->
              (* TODO: expose the payload to the API proper way *)
              Eio.Stream.add recv_stream (`Data payload);
              if end_stream then
                next_step
                  {
                    state with
                    streams =
                      Streams.stream_transition state.streams stream_id
                        (Half_closed Remote);
                  }
              else
                next_step
                  {
                    state with
                    streams = Streams.update_last_stream state.streams stream_id;
                  }
          | Half_closed (Local recv_stream) ->
              (* TODO: expose the payload to the API proper way *)
              Eio.Stream.add recv_stream (`Data payload);
              if end_stream then
                next_step
                  {
                    state with
                    streams =
                      Streams.stream_transition state.streams stream_id Closed;
                  }
              else
                next_step
                  {
                    state with
                    streams = Streams.update_last_stream state.streams stream_id;
                  })
      | Frame
          { frame_payload = Settings settings_l; frame_header = { flags; _ } }
        -> (
          let is_ack = Flags.test_ack flags in

          match (state.settings_status, is_ack) with
          | _, false ->
              Printf.printf "Received settings for update\n%!";
              let new_state =
                {
                  state with
                  client_settings =
                    Settings.update_with_list state.client_settings settings_l;
                }
              in
              (* write_settings f Settings.default ~ack:true (); *)
              (* wakeup_writer (); *)
              next_step new_state
          | Syncing new_settings, true ->
              Printf.printf "Received ACK settings\n%!";
              let new_state =
                {
                  state with
                  server_settings =
                    Settings.(
                      update_with_list state.server_settings
                        (to_settings_list new_settings));
                  settings_status = Idle;
                }
              in
              next_step new_state
          | Idle, true ->
              Printf.printf "Ouch! Received unexpected ACK settings\n%!";
              connection_error Error_code.ProtocolError
                "Unexpected ACK flag in SETTINGS frame.")
      | Frame { frame_payload = Ping _bs; _ } ->
          (* write_ping ~ack:true f bs; *)
          (* wakeup_writer (); *)
          next_step state
      | Frame
          {
            frame_payload = Headers (_, payload);
            frame_header = { flags; stream_id; _ };
            _;
          } -> (
          if state.shutdown then
            connection_error Error_code.ProtocolError
              "client tried to open a stream after sending GOAWAY"
          else if Flags.test_priority flags then
            connection_error Error_code.InternalError
              "Priority not yet implemented"
          else if not (Flags.test_end_header flags) then
            (* TODO: Save HEADERS payload as "in progress" and wait for CONTINUATION, no other frame from ANY stream should be received in this "in progress" state *)
            next_step state
          else
            let payload_parser =
              Hpack.Decoder.decode_headers state.hpack_decoder
            in
            let payload_result =
              Angstrom.parse_bigstring ~consume:Prefix payload_parser payload
            in

            match payload_result with
            | Error msg ->
                connection_error Error_code.CompressionError
                  (Format.sprintf "Parsing error: %s" msg)
            | Ok (Error _) ->
                connection_error Error_code.CompressionError
                  "Hpack decoding error"
            | Ok (Ok header_list) -> (
                let end_stream = Flags.test_end_stream flags in
                let pseudo_validation =
                  Headers.Pseudo.validate_request header_list
                in

                let stream_state =
                  Streams.state_of_id state.streams stream_id
                in

                match (end_stream, pseudo_validation) with
                | _, Invalid | false, No_pseudo ->
                    stream_error stream_id Error_code.ProtocolError
                | true, No_pseudo -> (
                    match stream_state with
                    | Open recv_stream ->
                        Eio.Stream.add recv_stream `EOF;
                        next_step
                          {
                            state with
                            streams =
                              Streams.stream_transition state.streams stream_id
                                (Half_closed Remote);
                          }
                    | Half_closed (Local recv_stream) ->
                        Eio.Stream.add recv_stream `EOF;
                        next_step
                          {
                            state with
                            streams =
                              Streams.stream_transition state.streams stream_id
                                Closed;
                          }
                    | Reserved _ ->
                        (* TODO: check if this is the correct error *)
                        stream_error stream_id Error_code.ProtocolError
                    | Idle -> stream_error stream_id Error_code.ProtocolError
                    | Closed | Half_closed Remote ->
                        connection_error Error_code.StreamClosed
                          "HEADERS received on a closed stream")
                | end_stream, Valid _pseudo -> (
                    (* get pseudo to API *)
                    match stream_state with
                    | Idle ->
                        next_step
                          {
                            state with
                            streams =
                              Streams.stream_transition state.streams stream_id
                                (if end_stream then Half_closed Remote
                                 else Open (Eio.Stream.create 0));
                          }
                    | Open recv_stream | Half_closed (Local recv_stream) ->
                        Eio.Stream.add recv_stream `EOF;
                        stream_error stream_id Error_code.ProtocolError
                    | Reserved _ ->
                        connection_error Error_code.ProtocolError
                          "HEADERS received on reserved stream"
                    | Half_closed Remote | Closed ->
                        connection_error Error_code.StreamClosed
                          "HEADERS received on closed stream")))
      | Frame { frame_payload = Continuation _; _ } ->
          failwith "CONTINUATION not yet implemented"
      | Frame
          { frame_payload = RSTStream _; frame_header = { stream_id; _ }; _ }
        -> (
          match Streams.state_of_id state.streams stream_id with
          | Idle ->
              connection_error Error_code.ProtocolError
                "RST_STREAM received on a idle stream"
          | Closed ->
              connection_error Error_code.StreamClosed
                "RST_STREAM received on a closed stream!"
          | _ ->
              (* TODO: check the error code and possibly pass it to API for error handling *)
              next_step
                {
                  state with
                  streams =
                    Streams.stream_transition state.streams stream_id Closed;
                })
      | Frame { frame_payload = PushPromise _; _ } ->
          connection_error Error_code.ProtocolError "client cannot push"
      | Frame { frame_payload = GoAway (last_stream_id, code, _msg); _ } -> (
          match code with
          | Error_code.NoError ->
              (* graceful shutdown *)
              (* TODO: when in the graceful shutdown state, we should check if all of the streams below last_stream_id are finished on each intent of closing a stream, meaning 
                     - each time RST_STREAM frame or END_HEADERS flag is sent or recieved, check if all streams left are closed, 
                     if yes, send server's GOAWAY *)
              let new_state =
                {
                  state with
                  shutdown = true;
                  streams =
                    Streams.update_last_stream ~strict:true state.streams
                      last_stream_id;
                }
              in
              next_step new_state
          | _ ->
              (* immediately shutdown the connection as the TCP connection should be closed by the client *)
              (* TODO: report this error to API to the connection error handler *)
              None)
      | Frame { frame_payload = WindowUpdate _; _ } -> Some state
      | Frame { frame_payload = Unknown _; _ } -> next_step state
      | Frame { frame_payload = Priority _; _ } -> next_step state
    in

    let read_io (state : state) (cs : Cstruct.t) : int * state option =
      let consumed, frames, _new_parse_state =
        Parse.read cs state.parse_state
      in
      let next_state =
        List.fold_left
          (fun state (frame : Parse.parse_result) ->
            match state with
            | None -> None
            | Some state -> frame_handler frame state)
          (Some state) frames
      in

      (consumed, next_state)
    in

    let initial_phase =
      initial_state
        (Settings.to_settings_list Settings.default)
        Settings.default
    in

    let default_max_frame = Settings.default.max_frame_size in
    Runloop.start ~max_frame_size:default_max_frame ~initial_state:initial_phase
      ~read_io ~write_io socket
  in
  Eio.Net.run_server ~on_error:ignore listen_socket connection_handler
