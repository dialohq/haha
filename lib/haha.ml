module StreamMap = Map.Make (Int32)

module Pseudo = struct
  let request_required = [| ":method"; ":scheme"; ":path" |]
end

type settings_sync = Syncing of Settings.t | Idle

type state = {
  client_settings : Settings.t;
  server_settings : Settings.t;
  settings_status : settings_sync;
  streams : Stream.t StreamMap.t;
  hpack_decoder : Hpack.Decoder.t;
}

type end_state = Error of Error_code.t * string
type step = Next_state of (state, Error.t) result | End_state of end_state

let initial_state recv_settings settings =
  {
    client_settings = Settings.(update_with_list default recv_settings);
    server_settings = Settings.default;
    settings_status = Syncing settings;
    streams = StreamMap.empty;
    hpack_decoder = Hpack.Decoder.create 1000;
  }

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

let write_window_update f stream_id n =
  Serialize.write_window_update_frame f stream_id n

let preface_handler f wakeup_writer (frame : Frame.t)
    (recv_settings : Settings.settings_list) =
  let { Frame.frame_header = { flags; _ }; _ } = frame in

  if Flags.test_ack flags then
    End_state
      (Error
         ( Error_code.ProtocolError,
           "Unexpected ACK flag in preface client SETTINGS frame." ))
  else
    let state = initial_state recv_settings Settings.default in

    write_settings f Settings.default ~ack:false ();
    (* TODO: start a timer and wait for settings ACK from the client - timeout error if no ACK *)
    write_settings f Settings.default ~ack:true ();
    write_window_update f Stream_identifier.connection
      Settings.WindowSize.initial_increment;
    wakeup_writer ();
    Next_state (Ok state)

let listen ~env:_ ~sw server_socket =
  let connection_handler socket (addr : Eio.Net.Sockaddr.stream) =
    (match addr with
    | `Unix s -> Printf.printf "Starting connection for %s\n%!" s
    | `Tcp (ip, port) ->
        Format.printf "Starting connection for %a:%i@." Eio.Net.Ipaddr.pp ip
          port);
    let receive_buffer = Cstruct.create 1000 in
    let read_bytes = Eio.Flow.single_read socket receive_buffer in
    Printf.printf "Read %i bytes\n%!" read_bytes;

    let parse_result =
      Angstrom.parse_bigstring ~consume:Prefix Parse.preface_parser
        (Cstruct.to_bigarray (Cstruct.sub receive_buffer 0 read_bytes))
    in
    Printf.printf "Parsing done\n%!";

    let frame, settings =
      match parse_result with
      | Error s -> failwith @@ Format.sprintf "Parsing error: %s\n%!" s
      | Ok (Error e) ->
          (* TODO: Report connection PROTOCOL ERROR, send GOAWAY *)
          failwith @@ Format.sprintf "Error: %s\n%!" (Error.message e)
      | Ok (Ok (frame, settings)) -> (frame, settings)
    in

    let f = Faraday.create 10_000 in
    let frame_stream = Eio.Stream.create 10 in

    Eio.Fiber.fork ~sw (fun () ->
        let rec loop () : unit =
          let read_bytes = Eio.Flow.single_read socket receive_buffer in

          let parse_result =
            match
              Angstrom.parse_bigstring ~consume:Prefix Parse.frame_parser
                (Cstruct.to_bigarray (Cstruct.sub receive_buffer 0 read_bytes))
            with
            | Error s -> failwith @@ Format.sprintf "Parsing error: %s\n%!" s
            | Ok res -> res
          in

          List.iter
            (function
              | Result.Error e ->
                  (* TODO: Report connection PROTOCOL ERROR, send GOAWAY *)
                  failwith @@ Format.sprintf "Error: %s\n%!" (Error.message e)
              | Ok frame -> Eio.Stream.add frame_stream frame)
            parse_result;
          loop ()
        in
        loop ());

    let write_condition = Eio.Condition.create () in
    let wakeup_writer () =
      Printf.printf "Waking up writer\n%!";
      Eio.Condition.broadcast write_condition
    in

    Eio.Fiber.fork ~sw (fun () ->
        let rec loop () : unit =
          match Faraday.operation f with
          | `Writev data_chunks ->
              Printf.printf "Writev operation\n%!";
              let bytes_written =
                List.fold_left
                  (fun acc (data : Bigstringaf.t Faraday.iovec) ->
                    let cs =
                      Cstruct.of_bigarray data.buffer ~off:data.off
                        ~len:data.len
                    in

                    Eio.Flow.write socket [ cs ];
                    acc + data.len)
                  0 data_chunks
              in

              Faraday.shift f bytes_written;

              loop ()
          | `Yield ->
              Printf.printf "Yield operation. Waiting for wakeup...\n%!";
              Eio.Condition.await_no_mutex write_condition;
              loop ()
          | `Close -> Printf.printf "Faraday closed\n%!"
        in
        loop ());

    let initial_step = preface_handler f wakeup_writer frame settings in

    let rec state_loop state =
      let connection_error error_code msg =
        state_loop (End_state (Error (error_code, msg)))
      in
      let stream_error stream_id code =
        state_loop (Next_state (Error (StreamError (stream_id, code))))
      in

      let step state = state_loop (Next_state (Ok state)) in

      match state with
      | Next_state (Error (ConnectionError (code, msg))) ->
          connection_error code msg
      | Next_state (Error (StreamError (stream_id, code))) ->
          let _ = (stream_id, code) in
          failwith "handle stream erra here"
      | Next_state (Ok state) -> (
          let ({ Frame.frame_header = { payload_length; _ }; _ } as frame) =
            Eio.Stream.take frame_stream
          in
          let _ = state.streams in

          if payload_length > state.server_settings.max_frame_size then
            state_loop (End_state (Error (Error_code.FrameSizeError, "")))
          else ();

          match frame with
          | { Frame.frame_payload = Data _; _ } ->
              Printf.printf "Got some data\n%!";
              (* validate the packet against existing streams if any and forward to the user, send WINDOW_UPDATE frames if needed *)
              step state
          | { frame_payload = Settings settings_l; frame_header = { flags; _ } }
            -> (
              let is_ack = Flags.test_ack flags in

              match (state.settings_status, is_ack) with
              | _, false ->
                  Printf.printf "Received settings for update\n%!";
                  (* good - update local settings, send ack *)
                  let new_state =
                    {
                      state with
                      client_settings =
                        Settings.update_with_list state.client_settings
                          settings_l;
                    }
                  in
                  write_settings f Settings.default ~ack:true ();
                  wakeup_writer ();
                  step new_state
              | Syncing new_settings, true ->
                  Printf.printf "Received ACK settings\n%!";
                  (* good -> we can now rely on new settings, update in state *)
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
                  step new_state
              | Idle, true ->
                  Printf.printf "Ouch! Received unexpected ACK settings\n%!";
                  (* dupa blada - unexpected ack, PROTOCOL ERROR *)
                  state_loop
                    (End_state
                       (Error
                          ( Error_code.ProtocolError,
                            "Unexpected ACK flag in SETTINGS frame." ))))
          | { frame_payload = Ping bs; _ } ->
              write_ping ~ack:true f bs;
              wakeup_writer ();

              step state
          | {
           frame_payload = Headers (_, payload);
           frame_header = { flags; stream_id; _ };
           _;
          } -> (
              if Flags.test_priority flags then
                state_loop
                @@ End_state
                     (Error
                        ( Error_code.InternalError,
                          "Priority not yet implemented" ))
              else if not (Flags.test_end_header flags) then
                (* TODO: Save stream and HEADERS payload as "in progress" and wait for CONTINUATION *)
                step state
              else
                let payload_parser =
                  Hpack.Decoder.decode_headers state.hpack_decoder
                in
                let payload_result =
                  Angstrom.parse_bigstring ~consume:Prefix payload_parser
                    payload
                in

                match payload_result with
                | Error msg ->
                    connection_error Error_code.CompressionError
                      (Format.sprintf "Parsing error: %s" msg)
                | Ok (Error _) ->
                    connection_error Error_code.CompressionError
                      "Hpack decoding error"
                | Ok (Ok header_list) -> (
                    (* TODO: after validating pseudo-headers we should use them correctly according to user's case in API *)
                    let valid_pseudo =
                      List.for_all
                        (fun header ->
                          Array.mem header.Hpack.name Pseudo.request_required)
                        header_list
                    in

                    if not valid_pseudo then
                      stream_error stream_id Error_code.ProtocolError
                    else
                      let end_stream = Flags.test_end_stream flags in
                      match StreamMap.find_opt stream_id state.streams with
                      | None | Some { state = Idle; _ } ->
                          step
                            {
                              state with
                              streams =
                                StreamMap.add stream_id
                                  {
                                    Stream.state =
                                      (if end_stream then Half_closed Remote
                                       else Open);
                                    id = stream_id;
                                  }
                                  state.streams;
                            }
                      | Some { state = Closed; _ } ->
                          connection_error Error_code.StreamClosed
                            "HEADERS received on closed stream!"
                      | Some { state = Open; _ } -> (
                          match end_stream with
                          | false ->
                              connection_error Error_code.ProtocolError
                                "unexpected HEADERS without END_STREAM flag on \
                                 open stream"
                          | true ->
                              step
                                {
                                  state with
                                  streams =
                                    StreamMap.add stream_id
                                      {
                                        Stream.state = Half_closed Remote;
                                        id = stream_id;
                                      }
                                      state.streams;
                                })
                      | Some { state = Half_closed Remote; _ } ->
                          stream_error stream_id Error_code.StreamClosed
                      | Some { state = Half_closed Local; _ } ->
                          step
                            {
                              state with
                              streams =
                                StreamMap.add stream_id
                                  { Stream.state = Closed; id = stream_id }
                                  state.streams;
                            }
                      | Some { state = Reserved _; _ } ->
                          failwith "to be implemented with PUSH_PROMISE"))
          | { frame_payload = Continuation _; _ } ->
              failwith "CONTINUATION not yet implemented"
          | { frame_header = { frame_type; _ }; _ } ->
              Printf.printf "Got some other frame of type: %i\n%!"
              @@ Frame.FrameType.serialize frame_type;
              step state)
      | End_state _end_state ->
          (*  send GOAWAY with error *)
          ()
    in

    state_loop initial_step
  in

  Eio.Net.run_server server_socket
    ~on_error:(fun e -> print_endline @@ Printexc.to_string e)
    connection_handler
