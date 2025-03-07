module StreamMap = Map.Make (Int32)

module Stream = struct
  type source = Remote | Local

  type state =
    | Idle
    | Reserved of source
    | Open
    | Half_closed of source
    | Closed

  type t = { id : Stream_identifier.t; state : state }
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

let stream_transition t stream_id state =
  if Stream_identifier.is_client stream_id then
    {
      t with
      last_client_stream = Int32.max stream_id t.last_client_stream;
      map = StreamMap.add stream_id { Stream.id = stream_id; state } t.map;
    }
  else
    {
      t with
      last_server_stream = Int32.max stream_id t.last_server_stream;
      map = StreamMap.add stream_id { Stream.id = stream_id; state } t.map;
    }

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

let state_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> Stream.Idle
  | Some stream -> stream.state
