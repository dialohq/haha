open Eio
open H2kit

type element = [ `Frame of (Frame.t, Error.t) result | `Magic of string ]

let run ~sw flow =
  let open Angstrom in
  Fiber.fork ~sw @@ fun () ->
  let parser : element t =
    Parsers.connection_preface
    >>| (fun c -> `Magic c)
    <|> (Parsers.parse_frame >>| fun f -> `Frame f)
  in

  let stream = Stream.create max_int in

  let buff = Cstruct.create Settings.default.max_frame_size in
  let read off = Flow.single_read flow (Cstruct.sub buff off 0) in

  let rec aux : element Unbuffered.state -> unit = function
    | Partial { committed; continue } -> ()
    | Done (consumed, e) ->
        Stream.add stream e;

        ()
    | Fail _ -> ()
  in

  ()
