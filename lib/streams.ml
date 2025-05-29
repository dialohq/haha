module StreamMap = Map.Make (Int32)

type client_peer = private Client
type server_peer = private Server

type 'c body_or_resp_writer =
  | BodyStream of 'c Body.writer
  | WritingResponse of 'c Response.response_writer

type 'context body_or_resp_reader =
  | BodyStream of 'context Body.reader
  | AwaitingResponse of 'context Response.handler

type (_, 'c) writers =
  | BodyWriter : 'c Body.writer -> (client_peer, 'c) writers
  | EitherWriter : 'c body_or_resp_writer -> (server_peer, 'c) writers

type (_, 'c) readers =
  | BodyReader : 'c Body.reader -> (server_peer, 'c) readers
  | EitherReader : 'c body_or_resp_reader -> (client_peer, 'c) readers

module Stream = struct
  type 'context error_handler = 'context -> Error_code.t -> 'context

  type ('peer, 'c) open_state = {
    readers : ('peer, 'c) readers;
    writers : ('peer, 'c) writers;
    error_handler : 'c error_handler;
    context : 'c;
  }

  type ('peer, 'c) half_closed =
    | Remote of {
        writers : ('peer, 'c) writers;
        error_handler : 'c error_handler;
        context : 'c;
      }
    | Local of {
        readers : ('peer, 'c) readers;
        error_handler : 'c error_handler;
        context : 'c;
      }

  type 'context reserved =
    | Remote of { error_handler : 'context error_handler; context : 'context }
    | Local of { error_handler : 'context error_handler; context : 'context }

  type ('peer, 'c) internal_state =
    | Idle
    | Reserved of 'c reserved
    | Open of ('peer, 'c) open_state
    | HalfClosed of ('peer, 'c) half_closed
    | Closed

  type 'peer state = State : ('peer, _) internal_state -> 'peer state
  type 'peer t = { state : 'peer state; flow : Flow_control.t }

  let pp_hum_generic fmt t =
    let open Format in
    fprintf fmt "@[<v 2>{";
    fprintf fmt "state = ";
    let (State state) = t.state in
    (match state with
    | Idle -> fprintf fmt "Idle"
    | Reserved (Remote _) -> fprintf fmt "Reserved Remote"
    | Reserved (Local _) -> fprintf fmt "Reserved Local"
    | Open { readers; writers; _ } ->
        fprintf fmt "@[<hv>Open (@,%a,@,%a)@]"
          (fun fmt _ -> fprintf fmt "<readers>")
          readers
          (fun fmt _ -> fprintf fmt "<writers>")
          writers
    | HalfClosed (Remote _) -> fprintf fmt "HalfClosed (Remote <writers>)"
    | HalfClosed (Local _) -> fprintf fmt "HalfClosed (Local <readers>)"
    | Closed -> fprintf fmt "Closed");
    fprintf fmt ";@ flow = %a" Flow_control.pp_hum t.flow;
    fprintf fmt "@]}"
end

type c_stream = client_peer Stream.t
type s_stream = server_peer Stream.t

type 'peer t = {
  map : 'peer Stream.t StreamMap.t;
  last_peer_stream : Stream_identifier.t;
      (** [last_peer_stream] is the last peer-initiated streams that was
          acknowledged/proccessed locally. This means we should update this
          value when receiving either HEADERS as a server or PUSH_PROMISE as a
          client. *)
  last_local_stream : Stream_identifier.t;
}

let initial () =
  {
    map = StreamMap.empty;
    last_peer_stream = Stream_identifier.connection;
    last_local_stream = Stream_identifier.connection;
  }

let stream_transition t id state =
  let map =
    StreamMap.update id
      (function
        | None -> Some { Stream.state; flow = Flow_control.initial }
        | Some _ when state = State Closed -> None
        | Some old -> Some { old with state })
      t.map
  in

  { t with map }

let count_open t =
  StreamMap.fold
    (fun _ (v : _ Stream.t) acc ->
      match v.state with
      | State (Open _) | State (HalfClosed _) -> acc + 1
      | _ -> acc)
    t.map 0

let count_active t = StreamMap.cardinal t.map

let get_next_id t = function
  | `Client ->
      if Stream_identifier.is_connection t.last_local_stream then 1l
      else Int32.add t.last_local_stream 2l
  | `Server ->
      if Stream_identifier.is_connection t.last_local_stream then 2l
      else Int32.add t.last_local_stream 2l

let update_last_peer_stream ?(strict = false) t stream_id =
  {
    t with
    last_peer_stream =
      (if strict then stream_id else Int32.max stream_id t.last_peer_stream);
  }

let update_last_local_stream id t =
  { t with last_local_stream = Int32.max id t.last_local_stream }

let incr_stream_out_flow t stream_id increment =
  let map =
    StreamMap.update stream_id
      (function
        | None -> None
        | Some (old : _ Stream.t) ->
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
        | Some (old : _ Stream.t) -> Some { old with flow = new_flow })
      t.map
  in

  { t with map }

let update_flow_on_data ~send_update id n t =
  let map =
    StreamMap.update id
      (function
        | None -> None
        | Some o ->
            Some
              {
                o with
                Stream.flow =
                  Flow_control.receive_data ~send_update o.Stream.flow n;
              })
      t.map
  in

  { t with map }

let all_closed t =
  StreamMap.for_all
    (fun _ (stream : _ Stream.t) ->
      match stream.state with State Closed -> true | _ -> false)
    t.map

let flow_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> Flow_control.initial
  | Some stream -> stream.flow

let state_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None when stream_id > t.last_local_stream && stream_id > t.last_peer_stream
    ->
      Stream.State Idle
  | None -> State Closed
  | Some stream -> stream.state
