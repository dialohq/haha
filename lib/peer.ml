type client = private C [@warning "-37"]
type server = private S [@warning "-37"]
type _ t = Client : client t | Server : server t

let is_local_id (type p) : p t -> int32 -> bool = function
  | Client -> Stream_identifier.is_client
  | Server -> Stream_identifier.is_server

let next_id (type p) : p t -> int32 -> int32 =
 fun t last_id ->
  match (t, last_id) with
  | Client, 0l -> 1l
  | Server, 0l -> 2l
  | _, id -> Int32.add id 2l
