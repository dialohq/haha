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
let frame_parser = parse_frame

let parsing_error msg =
  `Fail (Error.ConnectionError (Error_code.ProtocolError, msg))

let frame_parse state =
  match state with
  | AU.Partial { committed; continue } -> `Partial (committed, continue)
  | Fail (_, _, msg) -> parsing_error msg
  | Done (consumed, result') -> (
      match result' with
      | Error err -> `Fail err
      | Ok frame -> `Complete (consumed, frame))

let start_frame_parse bs ~off ~len frame_parser =
  let parser = AU.parse frame_parser in
  match parser with
  | Fail (_, _, msg) -> parsing_error msg
  | Done _ -> parsing_error "error parsing, malformed frame"
  | Partial { continue; _ } -> frame_parse (continue bs ~off ~len Incomplete)

let magic_parse bs ~off ~len =
  let parser = AU.parse magic_parser in
  match parser with
  | Fail (_, _, msg) -> parsing_error msg
  | Done _ -> parsing_error "error parsing connection preface string"
  | Partial { continue; _ } -> (
      match continue bs ~off ~len Incomplete with
      | Fail _ | Partial _ ->
          parsing_error "error parsing connection preface string"
      | Done (consumed, _) -> `Complete consumed)

let read (cs : Cstruct.t) (parse_state : parse_state) =
  let { Cstruct.buffer = bs; off; len = packet_len } = cs in
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
            else Ok (total_consumed + consumed, new_results, Frames None)
        | `Partial -> Ok (total_consumed, results, Magic)
        | `Fail err -> Error err)
    | Frames None -> (
        match start_frame_parse bs ~off ~len frame_parser with
        | `Complete (consumed, frame) ->
            let new_results = results @ [ Frame frame ] in
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                new_results
                (total_consumed + consumed)
                (Frames None)
            else Ok (total_consumed + consumed, new_results, Frames None)
        | `Partial (committed, continue) ->
            Ok (total_consumed + committed, results, Frames (Some continue))
        | `Fail err -> Error err)
    | Frames (Some continue) -> (
        match frame_parse (continue bs ~off ~len Incomplete) with
        | `Complete (consumed, frame) ->
            let new_results = results @ [ Frame frame ] in
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                new_results
                (total_consumed + consumed)
                (Frames None)
            else Ok (total_consumed + consumed, new_results, Frames None)
        | `Partial (committed, continue) ->
            Ok (total_consumed + committed, results, Frames (Some continue))
        | `Fail err -> Error err)
  in

  loop_frames bs ~off ~len:packet_len [] 0 parse_state
