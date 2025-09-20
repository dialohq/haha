open Effect.Deep

type event = Frame of Frame.t | Input of unit

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

type 'peer connection = {
  writer : Writer.t;
  streams : 'peer Streams.t;
  socket : [ `Flow | `W ] Eio.Resource.t;
  hpack_decoder : Hpack.Decoder.t;
  flow : Flow_control.t;
  (* those below should be something different probably *)
  initial_window : int32;
  max_frame_size : int;
}

let shutdown : 'a connection -> Error_code.t * string -> unit =
 fun _conn _ ->
  (* TODO: some cleanup in here idk *)
  ()

let update_with_settings :
    Settings.setting list ->
    'a connection ->
    ('a connection, Error_code.t * string) result =
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
        let streams =
          Streams.update_max_streams (Int32.to_int v) conn.streams
        in
        aux { conn with streams } rest
    | InitialWindowSize initial_window :: rest ->
        aux { conn with initial_window } rest
    | MaxFrameSize max_frame_size :: rest ->
        aux { conn with max_frame_size } rest
    | MaxHeaderListSize _ :: rest ->
        (* TODO: this is advisory, might implement later *)
        aux conn rest
  in

  aux conn settings

let rec run :
    'a connection -> event list -> ('a connection, Error_code.t * string) result
    =
 fun conn event ->
  let ( let* ) x y =
    match x with
    | Error err ->
        shutdown conn err;
        Error err
    | Ok v -> y v
  in

  let aux () =
    match event with
    | [] -> Ok conn
    | Frame { frame_payload = Ping data; _ } :: rest ->
        Writer.ping data ~ack:true conn.writer;
        run conn rest
    | Frame
        {
          frame_payload = Data data;
          frame_header = { stream_id = id; flags; _ };
        }
      :: rest ->
        let end_stream = Flags.test_end_stream flags in
        let* streams = Streams.read_data ~id ~end_stream data conn.streams in
        run { conn with streams } rest
    | Frame
        {
          frame_payload = Headers data;
          frame_header = { stream_id = id; flags; _ };
        }
      :: rest
      when Flags.test_end_header flags ->
        let* headers = decompress_headers_block data conn.hpack_decoder in
        let end_stream = Flags.test_end_stream flags in
        let* streams =
          Streams.receive_headers ~id ~end_stream headers conn.streams
        in
        run { conn with streams } rest
    | Frame { frame_payload = Headers _data; _ } :: _rest ->
        (* TODO: handle continuation headers *)
        assert false
    | Frame { frame_payload = Continuation _; _ } :: _rest -> assert false
    | Frame
        {
          frame_payload = RSTStream code;
          frame_header = { stream_id = id; _ };
          _;
        }
      :: rest ->
        let* streams = Streams.receive_rst ~id code conn.streams in
        run { conn with streams } rest
    | Frame { frame_payload = Settings l; _ } :: rest ->
        let* conn = update_with_settings l conn in
        Writer.settings_ack conn.writer;
        run conn rest
    | Frame { frame_payload = PushPromise _; _ } :: _rest ->
        (* TODO: again, peer-specific *)
        failwith "server push not implemented"
    | Frame { frame_payload = Unknown _ | Priority; _ } :: rest -> run conn rest
    | _ :: rest -> run conn rest
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
