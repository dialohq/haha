type t = GET | HEAD | POST | PUT | DELETE | CONNECT | OPTIONS | TRACE

let to_string = function
  | GET -> "GET"
  | HEAD -> "HEAD"
  | POST -> "POST"
  | PUT -> "PUT"
  | DELETE -> "DELETE"
  | CONNECT -> "CONNECT"
  | OPTIONS -> "OPTIONS"
  | TRACE -> "TRACE"

let of_string s =
  match String.uppercase_ascii s with
  | "GET" -> GET
  | "HEAD" -> HEAD
  | "POST" -> POST
  | "PUT" -> PUT
  | "DELETE" -> DELETE
  | "CONNECT" -> CONNECT
  | "OPTIONS" -> OPTIONS
  | "TRACE" -> TRACE
  | _ -> failwith "unknown"
