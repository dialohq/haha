open Eio
open H2kit
open Angstrom

type 'a continue = Cstruct.t -> 'a Unbuffered.state
type 'a state = { off : int; continue : 'a continue option }

let map_continue :
    (Bigstringaf.t ->
    off:int ->
    len:int ->
    Unbuffered.more ->
    _ Unbuffered.state) ->
    _ continue =
 fun continue { buffer; off; len } -> continue buffer ~off ~len Incomplete

let parse : _ t -> Cstruct.t -> _ Unbuffered.state =
 fun parser { buffer; off; len } ->
  match Unbuffered.parse parser with
  | Unbuffered.Partial { committed = 0; continue } ->
      continue buffer ~off ~len Incomplete
  | state -> state

let magic_parser = Parsers.connection_preface >>| fun _ -> Element.Magic

let frame_parser =
  Parsers.parse_frame >>| function
  | Ok frame -> Element.Frame frame
  | Error err -> ValidationFailed err

let parser : Element.t t =
  (* NOTE: we should do some smarter parsing to choose between magic and frames *)
  peek_string 3 >>= function "PRI" -> magic_parser | _ -> frame_parser

let read :
    flow:_ Eio.Resource.t ->
    buffer:Cstruct.t ->
    parser:_ t ->
    _ state ->
    Element.t list * _ state option =
 fun ~flow ~buffer:buff ~parser { off; continue } ->
  try
    let read =
      Flow.single_read flow Cstruct.(sub buff off (length buff - off))
    in

    let to_parse = Cstruct.(sub buff 0 (off + read)) in

    let rec aux :
        Element.t list ->
        int ->
        _ Unbuffered.state ->
        Element.t list * _ state option =
     fun acc consumed -> function
       | Fail _ -> (acc @ [ Malformed ], None)
       | Partial { committed; continue } ->
           let consumed = consumed + committed in
           let left = Cstruct.length to_parse - consumed in

           Cstruct.(blit buff consumed buff 0 left);

           (acc, Some { off = left; continue = Some (map_continue continue) })
       | Done (c, el) ->
           let new_consumed = consumed + c in
           let to_parse = Cstruct.shift to_parse new_consumed in
           aux (acc @ [ el ]) new_consumed (parse parser to_parse)
    in

    let parse = Option.value ~default:(parse parser) continue in

    aux [] 0 (parse to_parse)
  with End_of_file -> ([ EOF ], None)

let run :
    sw:Switch.t ->
    clock:float Eio.Time.clock_ty Eio.Resource.t ->
    _ Resource.t ->
    ((unit -> Element.t) -> 'a) ->
    'a =
 fun ~sw ~clock flow f ->
  let stream = Stream.create max_int in
  let stop_promise, stop_resolver = Promise.create () in
  Fiber.fork ~sw (fun () ->
      Fiber.first
        (fun () -> Promise.await stop_promise)
        (fun () ->
          let buffer = Cstruct.create Settings.default.max_frame_size in

          let rec aux state =
            let l, next = read ~flow ~buffer ~parser state in
            List.iter (Stream.add stream) l;
            Option.iter aux next
          in

          aux { off = 0; continue = None }));

  f (fun () ->
      Fiber.first
        (fun () -> Stream.take stream)
        (fun () ->
          Time.sleep clock 1.;
          Timeout));
  Promise.resolve stop_resolver ()
