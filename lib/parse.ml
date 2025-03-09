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

type parse_result = Magic_string | Frame of Frame.t

let magic_parser = connection_preface
let frame_parser = parse_frame

let parse_frame state =
  match state with
  | AU.Partial { committed; continue } -> `Partial (committed, continue)
  | Fail _ -> failwith "handle parsing error"
  | Done (consumed, result') -> (
      match result' with
      | Error _ -> failwith "handle stream/connection error from parsing"
      | Ok frame -> `Complete (consumed, frame))

let parse_frame_start bs ~off ~len =
  let parser = AU.parse frame_parser in
  match parser with
  | Fail _ -> failwith "handle parsing error"
  | Done _ -> failwith "unreachable"
  | Partial { continue; _ } -> parse_frame (continue bs ~off ~len Incomplete)

let parse_magic bs ~off ~len =
  let parser = AU.parse magic_parser in
  match parser with
  | Fail _ -> failwith "handle parsing error"
  | Done _ -> failwith "unreachable"
  | Partial { continue; _ } -> (
      match continue bs ~off ~len Incomplete with
      | Partial _ -> failwith "unreachable"
      | Fail _ -> `Partial
      | Done (consumed, _) -> `Complete consumed)

let frames initial_parse_state cs =
  let { Cstruct.buffer = bs; len = packet_len; off } = cs in

  let rec loop_frames bs ~off ~len (results : parse_result list) total_consumed
      parse_state =
    match parse_state with
    | Magic -> (
        match parse_magic bs ~off ~len with
        | `Complete consumed ->
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                (results @ [ Magic_string ])
                (total_consumed + consumed)
                (Frames None)
            else (total_consumed, results, Frames None)
        | `Partial -> (total_consumed, results, Magic))
    | Frames None -> (
        match parse_frame_start bs ~off ~len with
        | `Complete (consumed, frame) ->
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                (results @ [ Frame frame ])
                (total_consumed + consumed)
                (Frames None)
            else (total_consumed, results, Frames None)
        | `Partial (committed, continue) ->
            (total_consumed + committed, results, Frames (Some continue)))
    | Frames (Some continue) -> (
        match parse_frame (continue bs ~off ~len Incomplete) with
        | `Complete (consumed, frame) ->
            if total_consumed + consumed < packet_len then
              loop_frames bs ~off:(off + consumed) ~len:(len - consumed)
                (results @ [ Frame frame ])
                (total_consumed + consumed)
                (Frames None)
            else (total_consumed, results, Frames None)
        | `Partial (committed, continue) ->
            (total_consumed + committed, results, Frames (Some continue)))
  in
  (*
  1. n = 1 Magic:
    - partial
    - full
  2. n = many; Frames:
    - partial
    - many (1>=)
  *)

  loop_frames bs ~off ~len:packet_len [] 0 initial_parse_state

let read (cs : Cstruct.t) (parse_state : parse_state) :
    int * parse_result list * parse_state =
  let consumed, frames, next_parse_state = frames parse_state cs in
  (consumed, frames, next_parse_state)
