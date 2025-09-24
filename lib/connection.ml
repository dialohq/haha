open Effect.Deep

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

type shutdown =
  | Idle
  | AwaitingGoaway [@warning "-37"]
  | AwaitingClosedStreams
  | Close

type 'peer t = {
  writer : Writer.t;
  streams : 'peer Streams.t;
  hpack_decoder : Hpack.Decoder.t;
  flow : Flow_control.t; [@warning "-69"]
  reader : Reader.t;
  shutdown : shutdown;
}

type iteration =
  | End
  | Error of Error.connection_error
  | InProgress of (unit -> iteration)

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
    streams = Streams.init_client peer_settings.max_concurrent_streams;
    hpack_decoder = Hpack.Decoder.create user_settings.header_table_size;
    flow = Flow_control.initial;
    shutdown = Idle;
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
      Streams.init_server ~request_handler peer_settings.max_concurrent_streams;
    hpack_decoder = Hpack.Decoder.create user_settings.header_table_size;
    flow = Flow_control.initial;
    shutdown = Idle;
  }

let shutdown : 'a t -> Error_code.t * string -> unit =
 fun _conn _ ->
  (* TODO: some cleanup in here idk *)
  ()

let update_with_settings :
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
        let streams = Streams.update_max_streams v conn.streams in
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

let handle_frame : 'a t -> Frame.t -> ('a t, Error.connection_error) result =
 fun conn event ->
  let ( let* ) x y =
    match x with
    | Result.Error err ->
        shutdown conn err;
        Result.Error (Error.PeerError err)
    | Ok v -> y v
  in

  let aux () =
    match event with
    | { frame_payload = Ping data; _ } ->
        Writer.ping data ~ack:true conn.writer;
        Ok conn
    | { frame_payload = Data data; frame_header = { stream_id = id; flags; _ } }
      ->
        let end_stream = Flags.test_end_stream flags in
        let* streams = Streams.read_data ~id ~end_stream data conn.streams in
        Ok { conn with streams }
    | {
     frame_payload = Headers data;
     frame_header = { stream_id = id; flags; _ };
    }
      when Flags.test_end_header flags ->
        let* headers = decompress_headers_block data conn.hpack_decoder in
        let end_stream = Flags.test_end_stream flags in
        let* streams =
          Streams.receive_headers ~id ~end_stream headers conn.streams
        in
        Ok { conn with streams }
    | { frame_payload = Headers _data; _ } ->
        (* TODO: handle continuation headers *)
        assert false
    | { frame_payload = Continuation _; _ } -> assert false
    | {
     frame_payload = RSTStream code;
     frame_header = { stream_id = id; _ };
     _;
    } ->
        let* streams = Streams.receive_rst ~id code conn.streams in
        Ok { conn with streams }
    | { frame_payload = Settings l; _ } ->
        let* conn = update_with_settings l conn in
        Writer.settings_ack conn.writer;
        Ok conn
    | { frame_payload = PushPromise _; _ } ->
        (* TODO: again, peer-specific *)
        failwith "server push not implemented"
    | { frame_payload = Unknown _ | Priority; _ } -> Ok conn
    | { frame_payload = GoAway (_, NoError, _); _ } -> (
        match conn.shutdown with
        | AwaitingGoaway -> Ok { conn with shutdown = Close }
        | Close -> Ok conn
        | AwaitingClosedStreams -> Ok { conn with shutdown = Close }
        | Idle -> Ok { conn with shutdown = AwaitingClosedStreams })
    | { frame_payload = GoAway (_last_seen, code, debug_data); _ } ->
        (* TODO: process last_seen with Streams module *)
        Error (PeerError (code, Bigstringaf.to_string debug_data))
    | _ -> Ok conn
  in

  let effc : type c. c Effect.t -> ((c, 'b) continuation -> 'b) option =
   fun eff ->
    match eff with
    | Writer.Write write ->
        Some
          (fun k ->
            write conn.writer;
            continue k ())
    | _ -> None
  in

  match_with aux () { retc = (fun x -> x); exnc = raise; effc }

let handle_stream_error :
    'a t -> Error.stream_error -> ('a t, Error.connection_error) result =
 fun _conn _err -> failwith "stream erraaaaa!"

type 'a transition = 'a t -> ('a t, Error.connection_error) result

let make_read_event : Reader.t -> unit -> 'a transition =
 fun reader () ->
  let res = Reader.read_frame reader in
  fun conn ->
    match res with
    | Error (StreamError err) -> handle_stream_error conn err
    | Error (ConnectionError err) -> Error err
    | Ok frame -> handle_frame conn frame

let combine : 'a transition -> 'a transition -> 'a transition =
 fun tran1 tran2 t ->
  match tran1 t with Error _ as err -> err | Ok new_t -> tran2 new_t

let rec continue : 'a t -> iteration =
 fun t ->
  let read_event = make_read_event t.reader in

  let events = [ read_event ] in

  let transition = Eio.Fiber.any ~combine events in

  postprocess @@ Eio.Cancel.protect (fun () -> transition t)

and postprocess : ('a t, Error.connection_error) result -> iteration = function
  | Error err ->
      print_endline "conn erra inside";
      (* we should probably flush the writer first even if we got a connection error *)
      (*
        - send GOAWAY
        - error/on_close all streams
      *)
      Error err
  | Ok { shutdown = Close; _ } -> End
  | Ok { shutdown = AwaitingClosedStreams; streams; writer; _ }
    when Streams.active_streams streams = 0 -> (
      Writer.goaway (Streams.last_peer_stream streams) NoError writer;
      match Writer.flush writer with
      | Ok () -> End
      | Error exn -> postprocess (Error (Exn exn)))
  | Ok t -> (
      match Writer.flush t.writer with
      | Ok () -> InProgress (fun () -> continue t)
      | Error exn -> postprocess (Error (Exn exn)))

let start = postprocess
