module StreamMap = Map.Make (Int32)

type 'peer t = {
  map : 'peer Stream.t StreamMap.t;
  last_peer_stream : Stream_identifier.t;
  last_local_stream : Stream_identifier.t;
  max_local_streams : int32; [@warning "-69"]
  max_peer_streams : int32; [@warning "-69"]
  handle_headers : end_stream:bool -> Headers.t -> 'peer Stream.transition;
}

let init_client : int32 -> int32 -> Peer.client t =
 fun max_local_streams max_peer_streams ->
  {
    map = StreamMap.empty;
    last_peer_stream = 0l;
    last_local_stream = -1l;
    max_local_streams;
    max_peer_streams;
    handle_headers = Stream.receive_headers_client;
  }

let init_server :
    request_handler:Reqd.handler -> int32 -> int32 -> Peer.server t =
 fun ~request_handler max_local_streams max_peer_streams ->
  {
    map = StreamMap.empty;
    last_peer_stream = -1l;
    last_local_stream = 0l;
    max_local_streams;
    max_peer_streams;
    handle_headers = Stream.receive_headers_server ~request_handler;
  }

let last_peer_stream { last_peer_stream; _ } = last_peer_stream

let update_local_max : int32 -> 'a t -> 'a t =
 fun max_local_streams t -> { t with max_local_streams }

let update_peer_max : int32 -> 'a t -> 'a t =
 fun max_peer_streams t -> { t with max_peer_streams }

let active_streams : 'a t -> int =
 fun t ->
  StreamMap.fold
    (fun _ stream acc -> if Stream.is_active stream then acc + 1 else acc)
    t.map 0

let update_ids : Stream_identifier.t -> 'a t -> 'a t =
 fun id ({ last_peer_stream; last_local_stream; _ } as t) ->
  let open Stream_identifier in
  match
    (is_client id, is_client last_peer_stream, is_client last_local_stream)
  with
  | true, true, false | false, false, true ->
      { t with last_peer_stream = Int32.max last_peer_stream id }
  | true, false, true | false, true, false ->
      { t with last_local_stream = Int32.max last_local_stream id }
  | _, true, true | _, false, false ->
      (* initially we set odd and even values for those so this is unreachable *)
      assert false

let write_request :
    request:Request.t -> Peer.client t -> Peer.client t * Writer.write list =
 fun ~request t ->
  let id = Int32.add t.last_local_stream 2l in
  let new_stream, writes = Stream.init ~request id in
  let map = StreamMap.add id new_stream t.map in

  ({ t with map; last_local_stream = id }, writes)

let transition_stream :
    id:Stream_identifier.t ->
    'a Stream.transition ->
    'a t ->
    ('a t * Writer.write list, Error_code.t * string) result =
 fun ~id transition t ->
  let stream =
    match StreamMap.find_opt id t.map with
    | Some stream -> stream
    | None when id > t.last_local_stream -> Stream.create_idle ~id
    | None -> Stream.create_terminated ~id
  in

  let update_map (new_stream, writes) =
    let map =
      StreamMap.add id new_stream t.map
      |> StreamMap.filter (fun _ s -> not (Stream.is_eraseable s))
    in
    (update_ids id { t with map }, writes)
  in

  Result.map update_map (transition stream)

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
        (fun await_new () t ->
          let new_stream, writes = await_new () in
          let map = StreamMap.add id new_stream t.map in
          ({ t with map }, writes))
        (Stream.get_event stream))
    (StreamMap.bindings t.map)
