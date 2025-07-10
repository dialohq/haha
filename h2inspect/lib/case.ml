type action = GET of string | POST of string
type case = { port : int; scenerio : action list }

let yojson_of_action_list : action list -> Yojson.Safe.t =
 fun l ->
  `List
    (List.map
       (function
         | GET path -> `String (Format.asprintf "GET %s" path)
         | POST path -> `String (Format.asprintf "POST %s" path))
       l)

let yojson_of_cases : case list -> Yojson.Safe.t =
 fun l ->
  `List
    (List.map
       (fun { port; scenerio } ->
         `Assoc
           [ ("port", `Int port); ("scenerio", yojson_of_action_list scenerio) ])
       l)
