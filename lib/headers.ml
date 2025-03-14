type t = { name : string; value : string }

let of_hpack_list =
  List.map (fun hpack_header ->
      { name = hpack_header.Hpack.name; value = hpack_header.value })

let of_list = List.map (fun header -> { name = fst header; value = snd header })

module Pseudo = struct
  let request_required = [ ":method"; ":scheme"; ":path" ]
  let request_available = ":authority" :: request_required
  let response_required = [ ":status" ]

  type request_pseudo = {
    meth : string;
    scheme : string;
    path : string;
    authority : string option;
  }

  type 'message_type validation_result =
    | Invalid
    | Valid of 'message_type
    | No_pseudo

  let validate_request (recvd_headers : t list) =
    let headers =
      List.filter (fun header -> String.get header.name 0 = ':') recvd_headers
    in
    let rec check_all_present acc remaining required =
      match remaining with
      | [] -> acc && List.length required = 0
      | hd :: tl ->
          if List.mem hd required then
            check_all_present acc tl (List.filter (( <> ) hd) required)
          else false
    in
    let get_value header =
      match List.find_opt (fun h -> h.name = header) headers with
      | Some str -> str.value
      | None -> ""
    in
    let len = List.length headers in
    let names = List.map (fun header -> header.name) headers in
    if len = 0 then No_pseudo
    else if len = 3 && check_all_present true names request_required then
      Valid
        {
          meth = get_value ":method";
          scheme = get_value ":scheme";
          path = get_value ":path";
          authority = None;
        }
    else if len = 4 && check_all_present true names request_available then
      Valid
        {
          meth = get_value ":method";
          scheme = get_value ":scheme";
          path = get_value ":path";
          authority = Some (get_value ":authority");
        }
    else if len = 4 then Invalid
    else Invalid
end

(* TODO: should do more validation on normal headers here *)
