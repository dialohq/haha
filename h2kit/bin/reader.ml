open Eio
open H2kit
open Angstrom

type element = [ `Frame of (Frame.t, Error.t) result | `Magic | `Malformed ]
[@@deriving show { with_path = false }]

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

let run ~sw flow =
  Fiber.fork ~sw @@ fun () ->
  let parser : element t =
    Parsers.connection_preface
    >>| (fun _ -> `Magic)
    <|> (Parsers.parse_frame >>| fun f -> `Frame f)
  in

  let buff = Cstruct.create Settings.default.max_frame_size in

  let read : _ state -> element list * _ state option =
   fun { off; continue } ->
    let read =
      Flow.single_read flow Cstruct.(sub buff off (length buff - off))
    in

    let to_parse = Cstruct.(sub buff 0 (off + read)) in
    Printf.printf "%i bytes to parse:\n%!" @@ Cstruct.length to_parse;
    Cstruct.hexdump to_parse;

    let rec aux :
        element list ->
        int ->
        _ Unbuffered.state ->
        element list * _ state option =
     fun acc consumed -> function
       | Fail _ ->
           Printf.printf "Fail\n%!";
           (acc @ [ `Malformed ], None)
       | Partial { committed; continue } ->
           Printf.printf "Partial\n%!";
           let consumed = consumed + committed in
           let left = Cstruct.length to_parse - consumed in

           Cstruct.(blit buff consumed buff 0 left);

           (acc, Some { off = left; continue = Some (map_continue continue) })
       | Done (c, el) ->
           Printf.printf "Done, consumed %i\n%!" c;
           let new_consumed = consumed + c in
           let to_parse = Cstruct.shift to_parse new_consumed in
           Printf.printf "Rest to parse length %i\n%!"
           @@ Cstruct.length to_parse;
           aux (acc @ [ el ]) new_consumed (parse parser to_parse)
    in

    let parse = Option.value ~default:(parse parser) continue in

    aux [] 0 (parse to_parse)
  in

  let rec aux state =
    let open Format in
    let l, next = read state in

    printf "%a@."
      (pp_print_list ~pp_sep:(fun fmt () -> fprintf fmt " ") pp_element)
      l;

    Option.iter aux next
  in

  aux { off = 0; continue = None };

  Printf.printf "End of read\n%!"
