open Types
module StreamMap = Map.Make (Int32)

type server_writers =
  | BodyStream of body_writer
  | WritingResponse of Response.response_writer

type client_readers =
  | BodyStream of body_reader
  | AwaitingResponse of Request.response_handler

type client_writer = body_writer
type server_reader = body_reader

module Stream = struct
  type ('readers, 'writers) open_state = 'readers * 'writers

  type ('readers, 'writers) half_closed =
    | Remote of 'writers
    | Local of 'readers

  type reserved = Remote | Local

  type ('readers, 'writers) state =
    | Idle
    | Reserved of reserved
    | Open of ('readers, 'writers) open_state
    | Half_closed of ('readers, 'writers) half_closed
    | Closed

  type ('readers, 'writers) t = {
    id : Stream_identifier.t;
    state : ('readers, 'writers) state;
    flow : Flow_control.t;
  }
end

type ('readers, 'writers) t = {
  map : ('readers, 'writers) Stream.t StreamMap.t;
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

let get_next_id t = function
  | `Client ->
      if Stream_identifier.is_connection t.last_client_stream then 1l
      else Int32.add t.last_client_stream 2l
  | `Server ->
      if Stream_identifier.is_connection t.last_server_stream then 2l
      else Int32.add t.last_server_stream 2l

let change_writer (t : (server_reader, server_writers) t) id body_writer =
  let map =
    StreamMap.update id
      (function
        | None -> None
        | Some old -> (
            match old.Stream.state with
            | Open (body_reader, WritingResponse _) ->
                Some
                  {
                    old with
                    state = Open (body_reader, BodyStream body_writer);
                  }
            | Half_closed (Remote (WritingResponse _)) ->
                Some
                  {
                    old with
                    state = Half_closed (Remote (BodyStream body_writer));
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
        | Some (old : ('a, 'b) Stream.t) ->
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
        | Some (old : ('a, 'b) Stream.t) -> Some { old with flow = new_flow })
      t.map
  in

  { t with map }

let all_closed ?(last_stream_id = Int32.max_int) t =
  StreamMap.for_all
    (fun stream_id (stream : ('a, 'b) Stream.t) ->
      match (stream_id > last_stream_id, stream.state) with
      | true, _ -> true
      | false, Closed -> true
      | false, _ -> false)
    t.map

let combine_after_response t1 t2 =
  let map =
    StreamMap.union
      (fun _ (stream1 : (server_reader, server_writers) Stream.t)
           (stream2 : (server_reader, server_writers) Stream.t) ->
        let stream_state1, stream_state2 =
          (stream1.Stream.state, stream2.state)
        in

        match (stream_state1, stream_state2) with
        | Open (_, WritingResponse _), Open (_, BodyStream _)
        | ( Half_closed (Remote (WritingResponse _)),
            Half_closed (Remote (BodyStream _)) ) ->
            Some stream2
        | Open (_, BodyStream _), Open (_, WritingResponse _)
        | ( Half_closed (Remote (BodyStream _)),
            Half_closed (Remote (WritingResponse _)) ) ->
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

let response_writers t =
  StreamMap.fold
    (fun id (v : (server_reader, server_writers) Stream.t) (acc : 'a list) ->
      match v.state with
      | Open (body_reader, WritingResponse response_writer) ->
          (response_writer, Some body_reader, id) :: acc
      | Half_closed (Remote (WritingResponse response_writer)) ->
          (response_writer, None, id) :: acc
      | _ -> acc)
    t.map []

let body_writers t =
  match t with
  | `Server t ->
      StreamMap.fold
        (fun id (v : (server_reader, server_writers) Stream.t) (acc : 'a list)
           ->
          match v.state with
          | Open (_, BodyStream body_writer)
          | Half_closed (Remote (BodyStream body_writer)) ->
              (body_writer, id) :: acc
          | _ -> acc)
        t.map []
  | `Client t ->
      StreamMap.fold
        (fun id (v : (client_readers, client_writer) Stream.t) (acc : 'a list)
           ->
          match v.state with
          | Open (AwaitingResponse _, body_writer)
          | Open (BodyStream _, body_writer)
          | Half_closed (Remote body_writer) ->
              (body_writer, id) :: acc
          | _ -> acc)
        t.map []
