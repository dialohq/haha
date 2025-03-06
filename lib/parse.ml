open Angstrom
open Parsers

let preface_parser =
  connection_preface *> settings_preface >>= fun result ->
  match result with
  | Error (`Error e) -> return (Error e)
  | Ok (frame, settings) -> return (Ok (frame, settings))

let frame_parser = many parse_frame
