type header = { name : string; value : string }
type t = header list

let empty = []
let of_list = List.map (fun header -> { name = fst header; value = snd header })
let to_list = List.map (fun header -> (header.name, header.value))
let iter f = List.iter (fun header -> f (header.name, header.value))
let length = List.length
let join = List.concat

let make_response_headers ?(extra = []) status =
  of_list @@ ((":status", string_of_int status) :: extra)

let find_opt name l =
  match List.find_opt (fun h -> h.name = name) l with
  | None -> None
  | Some header -> Some header.value

module Pseudo = struct
  type request_pseudos = {
    meth : string;
    scheme : string;
    path : string;
    authority : string option;
  }

  type response_pseudos = { status : int }
  type pseudo = Request of request_pseudos | Response of response_pseudos
  type validation_result = NotPresent | Valid of pseudo | Invalid of string

  let request_mandatory_pseudos = [ ":method"; ":scheme"; ":path" ]
  let response_mandatory_pseudos = [ ":status" ]

  let all_defined_pseudos =
    request_mandatory_pseudos @ response_mandatory_pseudos @ [ ":authority" ]

  let is_pseudo_header_name name = String.length name > 0 && name.[0] = ':'

  let validate : header list -> validation_result =
   fun headers ->
    let get_value name hdr_list =
      match List.find_opt (fun h -> h.name = name) hdr_list with
      | None -> None
      | Some header -> Some header.value
    in

    let rec check_order header_list seen_regular_header =
      match header_list with
      | [] -> Ok ()
      | h :: t ->
          if is_pseudo_header_name h.name then
            if seen_regular_header then
              Error "Pseudo-header found after a regular header"
            else check_order t seen_regular_header
          else check_order t true
    in

    match check_order headers false with
    | Error msg -> Invalid msg
    | Ok () -> (
        let pseudo_headers, _ =
          List.partition (fun h -> is_pseudo_header_name h.name) headers
        in

        if pseudo_headers = [] then NotPresent
        else
          let pseudo_names = List.map (fun h -> h.name) pseudo_headers in

          let unique_names = List.sort_uniq String.compare pseudo_names in
          if List.length pseudo_names <> List.length unique_names then
            Invalid "Duplicate pseudo-headers"
          else if
            not
              (List.for_all
                 (fun name -> List.mem name all_defined_pseudos)
                 pseudo_names)
          then Invalid "Unknown pseudo-headers"
          else
            let method_opt = get_value ":method" pseudo_headers in
            let status_opt = get_value ":status" pseudo_headers in

            match (method_opt, status_opt) with
            | Some meth, None -> (
                match
                  ( get_value ":scheme" pseudo_headers,
                    get_value ":path" pseudo_headers )
                with
                | Some scheme, Some path ->
                    let authority = get_value ":authority" pseudo_headers in
                    Valid (Request { meth; scheme; path; authority })
                | _, _ ->
                    Invalid
                      "Missing mandatory request pseudo-headers (:method, \
                       :scheme, or :path)")
            | None, Some status -> (
                if
                  List.exists
                    (fun name ->
                      List.mem name
                        (request_mandatory_pseudos @ [ ":authority" ]))
                    pseudo_names
                then Invalid "Response contains request-specific pseudo-headers"
                else
                  try Valid (Response { status = int_of_string status })
                  with _ -> Invalid "Status should be a number")
            | Some _, Some _ ->
                Invalid
                  "Header list contains both request and response \
                   pseudo-headers"
            | None, None ->
                Invalid
                  "Pseudo-headers present but missing mandatory :method or \
                   :status")
end

let filter_out_pseudo =
  List.filter (fun { name; _ } -> not (Pseudo.is_pseudo_header_name name))
