type header = { name : string; value : string }
type t = header list

let of_list = List.map (fun header -> { name = fst header; value = snd header })
let to_list = List.map (fun header -> (header.name, header.value))

let find_opt name l =
  match List.find_opt (fun h -> h.name = name) l with
  | None -> None
  | Some header -> Some header.value
