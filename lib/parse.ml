module AU = Angstrom.Unbuffered

type continue =
  Bigstringaf.t ->
  off:int ->
  len:int ->
  AU.more ->
  (Frame.t, Error.t) result AU.state

let magic_parse bs ~off ~len =
  let parsing_error msg = Error (Error_code.ProtocolError, msg) in
  let parser = AU.parse Parsers.connection_preface in
  match parser with
  | Fail (_, _, msg) -> parsing_error msg
  | Done _ -> parsing_error "error parsing connection preface string"
  | Partial { continue; _ } -> (
      match continue bs ~off ~len Incomplete with
      | Fail _ | Partial _ ->
          parsing_error "error parsing connection preface string"
      | Done (consumed, _) -> Ok consumed)

let parsing_error msg consumed =
  `Fail (consumed, Error.ConnectionError (Error_code.ProtocolError, msg))

let continue_frame_parse state =
  match state with
  | AU.Partial { committed; continue } -> `Partial (committed, continue)
  | Fail (consumed, _, msg) -> parsing_error msg consumed
  | Done (consumed, result') -> (
      match result' with
      | Error err -> `Fail (consumed, err)
      | Ok frame -> `Complete (consumed, frame))

let start_frame_parse bs ~off ~len frame_parser =
  let parser = AU.parse frame_parser in
  match parser with
  | Fail (consumed, _, msg) -> parsing_error msg consumed
  | Done (consumed, _) ->
      parsing_error "error parsing, malformed frame" consumed
  | Partial { continue; _ } ->
      continue_frame_parse (continue bs ~off ~len Incomplete)

let parse_frame { Cstruct.buffer = bs; len; off } continue_opt =
  match continue_opt with
  | None -> start_frame_parse bs ~off ~len Parsers.parse_frame
  | Some continue -> continue_frame_parse (continue bs ~off ~len AU.Incomplete)

let read_frames ({ Cstruct.len = total_len; _ } as cs) =
  let rec loop_frames cs (results : Frame.t list) total_consumed continue_opt =
    match parse_frame cs continue_opt with
    | `Complete (consumed, frame) ->
        let new_results = results @ [ frame ] in
        if total_consumed + consumed < total_len then
          loop_frames
            (Cstruct.shift cs consumed)
            new_results
            (total_consumed + consumed)
            None
        else Ok (total_consumed + consumed, new_results, None)
    | `Partial (committed, continue) ->
        Ok (total_consumed + committed, results, Some continue)
    | `Fail err -> Error err
  in

  loop_frames cs [] 0 None
