(* TODO: own HPACK implementation and Eio-based parsing *)
let decompress_headers_block ?len bs hpack_decoder :
    (Headers.t, Error_code.t * string) result =
  let len = Option.value ~default:(Bigstringaf.length bs) len in
  let hpack_parser = Hpack.Decoder.decode_headers hpack_decoder in
  let compr_err msg = (Error_code.CompressionError, msg) in
  let error' ?msg () =
    Error
      (match msg with
      | None -> compr_err "Decompression error"
      | Some msg -> compr_err @@ Format.sprintf "Decompression error: %s" msg)
  in
  match Angstrom.Unbuffered.parse hpack_parser with
  | Fail (_, _, msg) -> error' ~msg ()
  | Done _ -> error' ()
  | Partial { continue; _ } -> (
      match continue bs ~off:0 ~len Complete with
      | Partial _ -> error' ()
      | Fail (_, _, msg) -> error' ~msg ()
      | Done (_, result') ->
          Result.map_error
            (fun _ -> compr_err "Decompression error, hpack error")
            result'
          |> Result.map (fun l ->
                 Headers.of_list
                 @@ List.rev_map
                      (fun hpack_header ->
                        (hpack_header.Hpack.name, hpack_header.value))
                      l))

type shutdown = Idle | Ongoing
type settings_sync = Idle | Syncing of Settings.t

type 'peer t = {
  writer : Writer.t;
  streams : 'peer Streams.t;
  hpack_decoder : Hpack.Decoder.t;
  flow : Flow_control.t; [@warning "-69"]
  reader : Reader.t;
  shutdown : shutdown;
  settings_sync : settings_sync;
}

type 'a iteration_base =
  [> `End
  | `Error of Error.connection_error
  | `Shutdown of unit -> 'a iteration_base ]
  as
  'a

let initial_client :
    writer:Writer.t ->
    reader:Reader.t ->
    Settings.t ->
    Settings.setting list ->
    Peer.client t =
 fun ~writer ~reader user_settings peer_settings ->
  let peer_settings = Settings.(update_with_list default peer_settings) in
  {
    reader;
    writer;
    streams =
      Streams.init_client peer_settings.max_concurrent_streams
        Settings.default.max_concurrent_streams;
    hpack_decoder = Hpack.Decoder.create Settings.default.header_table_size;
    flow = Flow_control.initial;
    shutdown = Idle;
    settings_sync = Syncing user_settings;
  }

let initial_server :
    writer:Writer.t ->
    reader:Reader.t ->
    request_handler:Reqd.handler ->
    Settings.t ->
    Settings.setting list ->
    Peer.server t =
 fun ~writer ~reader ~request_handler user_settings peer_settings ->
  let peer_settings = Settings.(update_with_list default peer_settings) in
  {
    reader;
    writer;
    streams =
      Streams.init_server ~request_handler peer_settings.max_concurrent_streams
        Settings.default.max_concurrent_streams;
    hpack_decoder = Hpack.Decoder.create Settings.default.header_table_size;
    flow = Flow_control.initial;
    shutdown = Idle;
    settings_sync = Syncing user_settings;
  }

let receive_settings :
    Settings.setting list -> 'a t -> ('a t, Error_code.t * string) result =
 fun settings conn ->
  let rec aux conn = function
    | [] -> Ok conn
    | Settings.HeaderTableSize v :: rest ->
        Writer.set_encoder_capacity conn.writer v;
        aux conn rest
    | EnablePush _ :: rest ->
        (* TODO: gotta thing about this, peer-specific *)
        aux conn rest
    | MaxConcurrentStreams v :: rest ->
        let streams = Streams.update_local_max v conn.streams in
        aux { conn with streams } rest
    | InitialWindowSize _initial_window :: _rest ->
        failwith "implement INITIAL_WINDOW_SIZE setting"
    | MaxFrameSize _ :: rest ->
        (* TODO: update the WRITER capacity *)
        aux conn rest
    | MaxHeaderListSize _ :: rest ->
        (* TODO: this is advisory, might implement later *)
        aux conn rest
  in

  aux conn settings

(* updating connection state with user's settings after receiving ACK *)
let update_with_settings :
    Settings.t -> 'a t -> ('a t, Error_code.t * string) result =
 fun settings t ->
  match
    Hpack.Decoder.set_capacity t.hpack_decoder settings.header_table_size
  with
  | Ok () ->
      let streams =
        Streams.update_peer_max settings.max_concurrent_streams t.streams
      in
      let reader = Reader.update_size settings.max_frame_size t.reader in
      Ok { t with streams; reader }
  | Error Decoding_error ->
      Error (InternalError, "failed to update capacity of the HPACK decoder")

let ( let* ) x y =
  match x with
  | Result.Error err -> Result.Error (Error.ProtocolViolation err)
  | Ok v -> y v

let handle_frame : 'a t -> Frame.t -> ('a t, Error.connection_error) result =
 fun conn event ->
  match event with
  | { frame_payload = Ping data; _ } ->
      Writer.ping data ~ack:true conn.writer;
      Ok conn
  | { frame_payload = Data data; frame_header = { stream_id = id; flags; _ } }
    ->
      let end_stream = Flags.test_end_stream flags in
      let* streams, writes =
        Streams.read_data ~id ~end_stream data conn.streams
      in
      List.iter (fun write -> write conn.writer) writes;
      Ok { conn with streams }
  | {
   frame_payload = Headers data;
   frame_header = { stream_id = id; flags; _ };
  }
    when Flags.test_end_header flags ->
      let* headers = decompress_headers_block data conn.hpack_decoder in
      let end_stream = Flags.test_end_stream flags in
      let* streams, writes =
        Streams.receive_headers ~id ~end_stream headers conn.streams
      in
      List.iter (fun write -> write conn.writer) writes;
      Ok { conn with streams }
  | { frame_payload = Headers _data; _ } ->
      (* TODO: handle continuation headers *)
      assert false
  | { frame_payload = Continuation _; _ } -> assert false
  | { frame_payload = RSTStream code; frame_header = { stream_id = id; _ }; _ }
    ->
      let* streams, writes = Streams.receive_rst ~id code conn.streams in
      List.iter (fun write -> write conn.writer) writes;
      Ok { conn with streams }
  | { frame_payload = Settings _; frame_header = { flags; _ } }
    when Flags.test_ack flags -> (
      match conn.settings_sync with
      | Idle ->
          Error
            (ProtocolViolation
               (ProtocolError, "unexpected SETTINGS with ACK flag"))
      | Syncing settings ->
          let* new_t =
            update_with_settings settings { conn with settings_sync = Idle }
          in
          Ok new_t)
  | { frame_payload = Settings l; _ } ->
      let* conn = receive_settings l conn in
      Writer.settings_ack conn.writer;
      Ok conn
  | { frame_payload = PushPromise _; _ } ->
      (* TODO: again, peer-specific *)
      failwith "server push not implemented"
  | { frame_payload = Unknown _ | Priority; _ } -> Ok conn
  | { frame_payload = GoAway (_, NoError, _); _ } -> (
      match conn.shutdown with
      | Ongoing -> Ok conn
      | Idle -> Ok { conn with shutdown = Ongoing })
  | { frame_payload = GoAway (_last_seen, code, debug_data); _ } ->
      (* TODO: process last_seen with Streams module *)
      Error (PeerError (code, Bigstringaf.to_string debug_data))
  | _ -> Ok conn

let handle_stream_error :
    'a t -> Error.stream_error -> ('a t, Error.connection_error) result =
 fun _conn _err -> failwith "stream erraaaaa!"

type 'a transition = 'a t -> ('a t, Error.connection_error) result

let make_read_event : Reader.t -> unit -> [> `Received ] * 'a transition =
 fun reader () ->
  let res = Reader.read_frame reader in
  let tran =
   fun conn ->
    match res with
    | Error (StreamError err) -> handle_stream_error conn err
    | Error (ConnectionError err) -> Error err
    | Ok frame -> handle_frame conn frame
  in
  (`Received, tran)

let make_user_events : 'a t -> (unit -> [> `Written ] * 'a transition) list =
 fun t ->
  List.map
    (fun event ->
      let transition = event () in
      let tran t =
        let streams, writes = transition t.streams in
        List.iter (fun write -> write t.writer) writes;
        Ok { t with streams }
      in
      fun () -> (`Written, tran))
    (Streams.get_events t.streams)

let combine ev1 ev2 =
  ( `Received,
    fun t ->
      match (ev1, ev2) with
      | (`Received, tran1), (`Received, tran2)
      | (`Written, tran1), (`Received, tran2)
      | (`Written, tran1), (`Written, tran2) ->
          Result.bind (tran1 t) tran2
      | (`Received, tran1), (`Written, tran2) -> Result.bind (tran2 t) tran1 )

type ('p, 'a) in_progress_f =
  'p Streams.t ->
  (bool -> 'p Streams.t -> Writer.write list -> 'a iteration_base) ->
  'a iteration_base

let rec continue :
    shutdown:bool -> ('a, 'b) in_progress_f -> 'a t -> 'b iteration_base =
 fun ~shutdown in_progress t ->
  let t = if shutdown then { t with shutdown = Ongoing } else t in

  let read_event = make_read_event t.reader in
  let user_events = make_user_events t in

  let _, transition = Eio.Fiber.any ~combine (read_event :: user_events) in

  let last_seen = Streams.last_peer_stream t.streams in
  postprocess in_progress last_seen t.writer
  @@ Eio.Cancel.protect (fun () -> transition t)

and postprocess :
    ('a, 'b) in_progress_f ->
    int32 ->
    Writer.t ->
    ('a t, Error.connection_error) result ->
    'b iteration_base =
 fun in_progress last_seen writer -> function
  | Error err ->
      (*
        - send GOAWAY
        - error/on_close all streams
      *)
      (match err with
      | PeerError _ -> ()
      | ProtocolViolation (code, msg) ->
          Writer.goaway ~debug_data:(Cstruct.of_string msg) last_seen code
            writer
      | Exn exn ->
          Writer.goaway
            ~debug_data:(Cstruct.of_string (Printexc.to_string exn))
            last_seen InternalError writer);

      Writer.flush writer |> ignore;
      `Error err
  | Ok { shutdown = Ongoing; streams; writer; _ }
    when Streams.active_streams streams = 0 -> (
      Writer.goaway (Streams.last_peer_stream streams) NoError writer;
      match Writer.flush writer with
      | Ok () -> `End
      | Error exn -> postprocess in_progress last_seen writer (Error (Exn exn)))
  | Ok t -> (
      match (Writer.flush t.writer, t.shutdown) with
      | Error exn, _ ->
          postprocess in_progress last_seen writer (Error (Exn exn))
      | Ok (), Idle ->
          in_progress t.streams (fun shutdown streams writes ->
              List.iter (fun write -> write t.writer) writes;
              continue ~shutdown in_progress { t with streams; writer })
      | Ok (), Ongoing ->
          `Shutdown (fun () -> continue ~shutdown:false in_progress t))

let start : ('a, 'b) in_progress_f -> 'a t -> 'b iteration_base =
 fun fn t ->
  let last_seen = Streams.last_peer_stream t.streams in
  postprocess fn last_seen t.writer (Ok t)

let handle_preface_error writer error =
  postprocess (fun _ _ -> `End) 0l writer (Error error)
