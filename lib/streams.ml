module IdMap = Map.Make (Int32)

type 'peer t = {
  peer : 'peer Peer.t;
  map : 'peer Stream.t IdMap.t;
  max_local_streams : int32; [@warning "-69"]
  max_peer_streams : int32; [@warning "-69"]
  handle_headers : end_stream:bool -> Headers.t -> 'peer Stream.transition;
}

let init_client : int32 -> int32 -> Peer.client t =
 fun max_local_streams max_peer_streams ->
  {
    peer = Client;
    map = IdMap.empty;
    max_local_streams;
    max_peer_streams;
    handle_headers = Stream.receive_headers_client;
  }

let init_server :
    request_handler:Reqd.handler -> int32 -> int32 -> Peer.server t =
 fun ~request_handler max_local_streams max_peer_streams ->
  {
    peer = Server;
    map = IdMap.empty;
    max_local_streams;
    max_peer_streams;
    handle_headers = Stream.receive_headers_server ~request_handler;
  }

let last_peer_stream t =
  IdMap.fold
    (fun id _ acc -> if Peer.is_local_id t.peer id then acc else max id acc)
    t.map 0l

let update_local_max : int32 -> 'a t -> 'a t =
 fun max_local_streams t -> { t with max_local_streams }

let update_peer_max : int32 -> 'a t -> 'a t =
 fun max_peer_streams t -> { t with max_peer_streams }

let active_streams : 'a t -> int =
 fun t ->
  IdMap.fold
    (fun _ stream acc -> if Stream.is_active stream then acc + 1 else acc)
    t.map 0

let write_request :
    request:Request.t -> Peer.client t -> Peer.client t * Writer.write list =
 fun ~request t ->
  let last_id =
    IdMap.fold
      (fun id _ acc -> if Peer.is_local_id t.peer id then max id acc else acc)
      t.map 0l
  in
  let id = Peer.next_id t.peer last_id in
  let new_stream, writes = Stream.init ~request id in
  let map = IdMap.add id new_stream t.map in

  ({ t with map }, writes)

let find_stream : id:Stream_identifier.t -> 'a Stream.t IdMap.t -> 'a Stream.t =
 fun ~id map ->
  let last_active =
    IdMap.fold
      (fun id stream acc -> if Stream.is_active stream then max id acc else acc)
      map 0l
  in

  match IdMap.find_opt id map with
  | Some stream -> stream
  | None when id > last_active -> Stream.create_idle ~id
  | None -> Stream.create_terminated ~id

let transition_stream :
    id:Stream_identifier.t ->
    'a Stream.transition ->
    'a t ->
    ('a t * Writer.write list, Error_code.t * string) result =
 fun ~id transition t ->
  let update_map (new_stream, writes) =
    let map =
      IdMap.add id new_stream t.map
      |> IdMap.filter (fun _ s -> not (Stream.is_eraseable s))
    in
    ({ t with map }, writes)
  in

  Result.map update_map (transition (find_stream ~id t.map))

let read_data ~id ~end_stream data =
  transition_stream ~id (Stream.read_data ~end_stream data)

let receive_headers ~id ~end_stream headers t =
  transition_stream ~id (t.handle_headers ~end_stream headers) t

let receive_rst ~id code = transition_stream ~id (Stream.receive_rst code)

let get_events : 'a t -> (unit -> 'a t -> 'a t * Writer.write list) list =
 fun t ->
  List.filter_map
    (fun (id, stream) ->
      Option.map
        (fun await_new () ->
          let transition = await_new () in
          fun t ->
            let update_map (new_stream, writes) =
              let map =
                IdMap.add id new_stream t.map
                |> IdMap.filter (fun _ s -> not (Stream.is_eraseable s))
              in
              ({ t with map }, writes)
            in
            update_map (transition (find_stream ~id t.map)))
        (Stream.get_event stream))
    (IdMap.bindings t.map)
