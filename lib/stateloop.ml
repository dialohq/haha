open Writer
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
}

let shutdown : 'a connection -> Error_code.t * string -> unit =
 fun _conn _ ->
  (* TODO: some cleanup in here idk *)
  ()

let rec run :
    'a connection -> event list -> ('a connection, Error_code.t * string) result
    =
 fun conn event ->
  let ( => ) x y =
    match x with
    | Error err ->
        shutdown conn err;
        Error err
    | Ok v -> y v
  in

  let ( let* ) = ( => ) in

  let aux () =
    match event with
    | [] -> Ok conn
    | Frame { frame_payload = Ping data; _ } :: rest ->
        ping data ~ack:true conn.writer;
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
