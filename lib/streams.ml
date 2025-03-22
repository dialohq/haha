module StreamMap = Map.Make (Int32)

module Stream = struct
  type stream_reader = Cstruct.t -> unit

  type stream_writers =
    | Responded of Response.body_writer
    | Responding of Response.response_writer

  type half_closed = Remote of stream_writers | Local of stream_reader
  type reserved = Remote | Local

  type state =
    | Idle
    | Reserved of reserved
    | Open of stream_reader * stream_writers
    | Half_closed of half_closed
    | Closed

  type t = { id : Stream_identifier.t; state : state; flow : Flow_control.t }
end

type t = {
  map : Stream.t StreamMap.t;
  last_client_stream : Stream_identifier.t;
  last_server_stream : Stream_identifier.t;
}

let initial =
  {
    map = StreamMap.empty;
    last_client_stream = Stream_identifier.connection;
    last_server_stream = Stream_identifier.connection;
  }

let stream_transition t id state =
  let map =
    StreamMap.update id
      (function
        | None -> Some { Stream.id; state; flow = Flow_control.initial }
        | Some old -> Some { old with state })
      t.map
  in

  if Stream_identifier.is_client id then
    { t with last_client_stream = Int32.max id t.last_client_stream; map }
  else { t with last_server_stream = Int32.max id t.last_server_stream; map }

let change_writer t id body_writer =
  let map =
    StreamMap.update id
      (function
        | None -> None
        | Some old -> (
            match old.Stream.state with
            | Open (stream_handler, Responding _) ->
                Some
                  {
                    old with
                    state = Open (stream_handler, Responded body_writer);
                  }
            | Half_closed (Remote (Responding _)) ->
                Some
                  {
                    old with
                    state = Half_closed (Remote (Responded body_writer));
                  }
            | _ -> Some old))
      t.map
  in
  { t with map }

let update_last_stream ?(strict = false) t stream_id =
  if Stream_identifier.is_client stream_id then
    {
      t with
      last_client_stream =
        (if strict then stream_id else Int32.max stream_id t.last_client_stream);
    }
  else
    {
      t with
      last_server_stream =
        (if strict then stream_id else Int32.max stream_id t.last_server_stream);
    }

let incr_stream_out_flow t stream_id increment =
  let map =
    StreamMap.update stream_id
      (function
        | None -> None
        | Some (old : Stream.t) ->
            Some
              { old with flow = Flow_control.incr_out_flow old.flow increment })
      t.map
  in

  { t with map }

let update_stream_flow t stream_id new_flow =
  let map =
    StreamMap.update stream_id
      (function
        | None -> None
        | Some (old : Stream.t) -> Some { old with flow = new_flow })
      t.map
  in

  { t with map }

let all_closed ?(last_stream_id = Int32.max_int) t =
  StreamMap.for_all
    (fun stream_id (stream : Stream.t) ->
      match (stream_id > last_stream_id, stream.state) with
      | true, _ -> true
      | false, Closed -> true
      | false, _ -> false)
    t.map

let combine_after_response t1 t2 =
  let map =
    StreamMap.union
      (fun _ stream1 stream2 ->
        let stream_state1, stream_state2 =
          (stream1.Stream.state, stream2.state)
        in

        match (stream_state1, stream_state2) with
        | Open (_, Responding _), Open (_, Responded _)
        | ( Half_closed (Remote (Responding _)),
            Half_closed (Remote (Responded _)) ) ->
            Some stream2
        | Open (_, Responded _), Open (_, Responding _)
        | ( Half_closed (Remote (Responded _)),
            Half_closed (Remote (Responding _)) ) ->
            Some stream1
        | _ -> Some stream1)
      t1.map t2.map
  in

  {
    map;
    last_client_stream = Int32.max t1.last_client_stream t2.last_client_stream;
    last_server_stream = Int32.max t1.last_server_stream t2.last_server_stream;
  }

let flow_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> None
  | Some stream -> Some stream.flow

let state_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> Stream.Idle
  | Some stream -> stream.state

let get_user_writes t =
  StreamMap.fold
    (fun id (v : Stream.t) (acc : 'a list) ->
      match v.state with
      | Open (reader, Responding response_writer) ->
          `ResponseWriter (response_writer, Some reader, id) :: acc
      | Half_closed (Remote (Responding response_writer)) ->
          `ResponseWriter (response_writer, None, id) :: acc
      | Open (_, Responded body_writer)
      | Half_closed (Remote (Responded body_writer)) ->
          `BodyWriter (body_writer, id) :: acc
      | _ -> acc)
    t.map []
