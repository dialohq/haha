open Types
module StreamMap = Map.Make (Int32)

type server_writers =
  | BodyStream of body_writer
  | WritingResponse of Response.response_writer

let pp_hum_server_writers fmt = function
  | BodyStream _ -> Format.fprintf fmt "BodyStream <body_writer>"
  | WritingResponse _ -> Format.fprintf fmt "WritingResponse <response_writer>"

type client_readers =
  | BodyStream of body_reader
  | AwaitingResponse of Request.response_handler

let pp_hum_client_readers fmt = function
  | BodyStream _ -> Format.fprintf fmt "BodyStream <body_reader>"
  | AwaitingResponse _ ->
      Format.fprintf fmt "AwaitingResponse <response_handler>"

type client_writer = body_writer
type server_reader = body_reader

let pp_hum_client_writer fmt (_ : client_writer) =
  Format.fprintf fmt "BodyStream <body_writer>"

let pp_hum_server_reader fmt (_ : server_reader) =
  Format.fprintf fmt "BodyStream <body_reader>"

module Stream = struct
  type error_handler = Error_code.t -> unit

  type ('readers, 'writers) open_state = {
    readers : 'readers;
    writers : 'writers;
    error_handler : error_handler;
  }

  type ('readers, 'writers) half_closed =
    | Remote of { writers : 'writers; error_handler : error_handler }
    | Local of { readers : 'readers; error_handler : error_handler }

  type reserved =
    | Remote of { error_handler : error_handler }
    | Local of { error_handler : error_handler }

  type ('readers, 'writers) state =
    | Idle
    | Reserved of reserved
    | Open of ('readers, 'writers) open_state
    | HalfClosed of ('readers, 'writers) half_closed
    | Closed

  type ('readers, 'writers) t = {
    state : ('readers, 'writers) state;
    flow : Flow_control.t;
  }

  let pp_hum_generic fmt t =
    let open Format in
    fprintf fmt "@[<v 2>{";
    fprintf fmt "state = ";
    (match t.state with
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

  let pp_hum pp_readers pp_writers fmt t =
    let open Format in
    fprintf fmt "@[<v 2>{";
    fprintf fmt "state = ";
    (match t.state with
    | Idle -> fprintf fmt "Idle"
    | Reserved (Remote _) -> fprintf fmt "Reserved Remote"
    | Reserved (Local _) -> fprintf fmt "Reserved Local"
    | Open { readers; writers; _ } ->
        fprintf fmt "@[<hv>Open (@,%a,@,%a)@]" pp_readers readers pp_writers
          writers
    | HalfClosed (Remote { writers; _ }) ->
        fprintf fmt "HalfClosed (Remote %a)" pp_writers writers
    | HalfClosed (Local { readers; _ }) ->
        fprintf fmt "HalfClosed (Local %a)" pp_readers readers
    | Closed -> fprintf fmt "Closed");
    fprintf fmt ";@ flow = %a" Flow_control.pp_hum t.flow;
    fprintf fmt "@]}"
end

type c_stream = (client_readers, client_writer) Stream.t
type s_stream = (server_reader, server_writers) Stream.t

type ('readers, 'writers) t = {
  map : ('readers, 'writers) Stream.t StreamMap.t;
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
        | Some _ when state = Closed -> None
        | Some old -> Some { old with state })
      t.map
  in

  { t with map }

let count_open t =
  StreamMap.fold
    (fun _ (v : ('a, 'b) Stream.t) acc ->
      match v.state with Open _ | HalfClosed _ -> acc + 1 | _ -> acc)
    t.map 0

let get_next_id t = function
  | `Client ->
      if Stream_identifier.is_connection t.last_local_stream then 1l
      else Int32.add t.last_local_stream 2l
  | `Server ->
      if Stream_identifier.is_connection t.last_local_stream then 2l
      else Int32.add t.last_local_stream 2l

let change_writer (t : (server_reader, server_writers) t) id body_writer =
  let map =
    StreamMap.update id
      (function
        | None -> None
        | Some old -> (
            match old.Stream.state with
            | Open ({ writers = WritingResponse _; _ } as state) ->
                Some
                  {
                    old with
                    state = Open { state with writers = BodyStream body_writer };
                  }
            | HalfClosed (Remote ({ writers = WritingResponse _; _ } as state))
              ->
                Some
                  {
                    old with
                    state =
                      HalfClosed
                        (Remote { state with writers = BodyStream body_writer });
                  }
            | _ -> Some old))
      t.map
  in
  { t with map }

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
    (fun _ (stream : ('a, 'b) Stream.t) ->
      match stream.state with Closed -> true | _ -> false)
    t.map

let flow_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> Flow_control.initial
  | Some stream -> stream.flow

let state_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None when stream_id > t.last_local_stream -> Stream.Idle
  | None -> Closed
  | Some stream -> stream.state

let response_writers t =
  StreamMap.fold
    (fun id (v : (server_reader, server_writers) Stream.t) (acc : 'a list) ->
      match v.state with
      | Open
          {
            readers = body_reader;
            writers = WritingResponse response_writer;
            error_handler;
          } ->
          (response_writer, Some body_reader, id, error_handler) :: acc
      | HalfClosed
          (Remote
             { writers = WritingResponse response_writer; error_handler; _ }) ->
          (response_writer, None, id, error_handler) :: acc
      | _ -> acc)
    t.map []

(* TODO: could do GADT for such cases *)
let body_writers t =
  match t with
  | `Server t ->
      StreamMap.fold
        (fun id (v : s_stream) (acc : 'a list) ->
          match v.state with
          | Open { writers = BodyStream body_writer; _ }
          | HalfClosed (Remote { writers = BodyStream body_writer; _ }) ->
              ((fun () -> body_writer ~window_size:v.flow.out_flow), id) :: acc
          | _ -> acc)
        t.map []
  | `Client t ->
      StreamMap.fold
        (fun id (v : c_stream) (acc : 'a list) ->
          match v.state with
          | Open { writers = body_writer; _ }
          | HalfClosed (Remote { writers = body_writer; _ }) ->
              ((fun () -> body_writer ~window_size:v.flow.out_flow), id) :: acc
          | _ -> acc)
        t.map []

let pp_hum_generic fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "map = <length %i> @[<v 2>{" @@ StreamMap.cardinal t.map;
  StreamMap.iter
    (fun key value ->
      match value.Stream.state with
      | Open _ | Reserved _ | HalfClosed _ ->
          fprintf fmt "%ld -> %a;@ " key Stream.pp_hum_generic value
      | _ -> ())
    t.map;
  fprintf fmt "}@];";
  fprintf fmt "@ last_peer_stream = %ld;" t.last_peer_stream;
  fprintf fmt "@ last_local_stream = %ld" t.last_local_stream;
  fprintf fmt "@]}"

let pp_hum pp_readers pp_writers fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "map = <length %i> @[<v 2>{" @@ StreamMap.cardinal t.map;
  StreamMap.iter
    (fun key value ->
      match value.Stream.state with
      | Open _ | Reserved _ | HalfClosed _ ->
          fprintf fmt "%ld -> %a;@ " key
            (Stream.pp_hum pp_readers pp_writers)
            value
      | _ -> ())
    t.map;
  fprintf fmt "}@];";
  fprintf fmt "@ last_peer_stream = %ld;" t.last_peer_stream;
  fprintf fmt "@ last_local_stream = %ld" t.last_local_stream;
  fprintf fmt "@]}"
