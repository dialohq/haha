open Angstrom
open Parsers
module AU = Angstrom.Unbuffered

type parse_state =
  | Magic
  | Frames of
      (bigstring ->
      off:int ->
      len:int ->
      AU.more ->
      (Frame.t, Error.t) result AU.state)
      option

let magic_parser = connection_preface

let frame_parse state =
  match state with
  | AU.Partial { committed; continue } -> `Partial (committed, continue)
  | Fail _ -> failwith "handle parsing error"
  | Done (consumed, result') -> (
      match result' with
      | Error _ -> failwith "handle stream/connection error from parsing"
      | Ok frame -> `Complete (consumed, frame))

let start_frame_parse bs ~off ~len frame_parser =
  let parser = AU.parse frame_parser in
  match parser with
  | Fail _ -> failwith "handle parsing error"
  | Done _ -> failwith "unreachable"
  | Partial { continue; _ } -> frame_parse (continue bs ~off ~len Incomplete)

let magic_parse bs ~off ~len =
  let parser = AU.parse magic_parser in
  match parser with
  | Fail _ -> failwith "handle parsing error"
  | Done _ -> failwith "unreachable"
  | Partial { continue; _ } -> (
      match continue bs ~off ~len Incomplete with
      | Partial _ -> failwith "unreachable"
      | Fail _ -> `Partial
      | Done (consumed, _) -> `Complete consumed)

let read (cs : Cstruct.t) (parse_state : parse_state)
    (hpack_decoder : Hpack.Decoder.t) =
  let { Cstruct.buffer = bs; off; len = packet_len } = cs in
  let frame_parser = parse_frame hpack_decoder in
  let rec loop_frames bs ~off ~len (results : Message.t list) total_consumed
      parse_state =
    match parse_state with
    | Magic -> (
        match magic_parse bs ~off ~len with
        | `Complete consumed ->
            let new_results = results @ [ Magic_string ] in
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                new_results
                (total_consumed + consumed)
                (Frames None)
            else (total_consumed + consumed, new_results, Frames None)
        | `Partial -> (total_consumed, results, Magic))
    | Frames None -> (
        match start_frame_parse bs ~off ~len frame_parser with
        | `Complete (consumed, frame) ->
            let new_results = results @ [ Frame frame ] in
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                new_results
                (total_consumed + consumed)
                (Frames None)
            else (total_consumed + consumed, new_results, Frames None)
        | `Partial (committed, continue) ->
            (total_consumed + committed, results, Frames (Some continue)))
    | Frames (Some continue) -> (
        match frame_parse (continue bs ~off ~len Incomplete) with
        | `Complete (consumed, frame) ->
            let new_results = results @ [ Frame frame ] in
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                new_results
                (total_consumed + consumed)
                (Frames None)
            else (total_consumed + consumed, new_results, Frames None)
        | `Partial (committed, continue) ->
            (total_consumed + committed, results, Frames (Some continue)))
  in

  loop_frames bs ~off ~len:packet_len [] 0 parse_state
