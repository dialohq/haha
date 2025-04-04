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
  type ('readers, 'writers) open_state = 'readers * 'writers

  type ('readers, 'writers) half_closed =
    | Remote of 'writers
    | Local of 'readers

  type reserved = Remote | Local

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
    | Reserved Remote -> fprintf fmt "Reserved Remote"
    | Reserved Local -> fprintf fmt "Reserved Local"
    | Open (readers, writers) ->
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
    | Reserved Remote -> fprintf fmt "Reserved Remote"
    | Reserved Local -> fprintf fmt "Reserved Local"
    | Open (readers, writers) ->
        fprintf fmt "@[<hv>Open (@,%a,@,%a)@]" pp_readers readers pp_writers
          writers
    | HalfClosed (Remote writers) ->
        fprintf fmt "HalfClosed (Remote %a)" pp_writers writers
    | HalfClosed (Local readers) ->
        fprintf fmt "HalfClosed (Local %a)" pp_readers readers
    | Closed -> fprintf fmt "Closed");
    fprintf fmt ";@ flow = %a" Flow_control.pp_hum t.flow;
    fprintf fmt "@]}"
end

type c_stream = (client_readers, client_writer) Stream.t
type s_stream = (server_reader, server_writers) Stream.t

type ('readers, 'writers) t = {
  map : ('readers, 'writers) Stream.t StreamMap.t;
  last_client_stream : Stream_identifier.t;
  last_server_stream : Stream_identifier.t;
}

let initial () =
  {
    map = StreamMap.empty;
    last_client_stream = Stream_identifier.connection;
    last_server_stream = Stream_identifier.connection;
  }

let stream_transition t id state =
  let map =
    StreamMap.update id
      (function
        | None -> Some { Stream.state; flow = Flow_control.initial }
        | Some old -> Some { old with state })
      t.map
  in

  if Stream_identifier.is_client id then
    { t with last_client_stream = Int32.max id t.last_client_stream; map }
  else { t with last_server_stream = Int32.max id t.last_server_stream; map }

let count_open t =
  StreamMap.fold
    (fun _ (v : ('a, 'b) Stream.t) acc ->
      match v.state with Open _ | HalfClosed _ -> acc + 1 | _ -> acc)
    t.map 0

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
            | HalfClosed (Remote (WritingResponse _)) ->
                Some
                  {
                    old with
                    state = HalfClosed (Remote (BodyStream body_writer));
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

let combine_server_streams t1 t2 =
  let map =
    StreamMap.union
      (fun _ (stream1 : s_stream) (stream2 : s_stream) ->
        let flow = Flow_control.max stream1.flow stream2.flow in
        match (stream1.state, stream2.state) with
        | _, Idle | Closed, Open _ | Closed, HalfClosed _ ->
            Some { stream1 with flow }
        | Open (_, WritingResponse _), Open (_, BodyStream _)
        | ( HalfClosed (Remote (WritingResponse _)),
            HalfClosed (Remote (BodyStream _)) ) ->
            Some { stream2 with flow }
        | Open (_, BodyStream _), Open (_, WritingResponse _)
        | ( HalfClosed (Remote (BodyStream _)),
            HalfClosed (Remote (WritingResponse _)) ) ->
            Some { stream1 with flow }
        | HalfClosed (Remote _), HalfClosed (Local _)
        | HalfClosed (Local _), HalfClosed (Remote _) ->
            Some { flow; state = Closed }
        | HalfClosed (Local _r), Open (r, _w) ->
            Some { flow; state = HalfClosed (Local r) }
        | HalfClosed (Remote _w), Open (_r, w) ->
            Some { flow; state = HalfClosed (Remote w) }
        | Idle, _ | Open _, Closed | HalfClosed _, Closed ->
            Some { stream2 with flow }
        | Open (r, _w), HalfClosed (Local _r) ->
            Some { flow; state = HalfClosed (Local r) }
        | Open (_r, w), HalfClosed (Remote _w) ->
            Some { flow; state = HalfClosed (Remote w) }
        | _ -> Some { stream1 with flow })
      t1.map t2.map
  in

  {
    map;
    last_client_stream = Int32.max t1.last_client_stream t2.last_client_stream;
    last_server_stream = Int32.max t1.last_server_stream t2.last_server_stream;
  }

let combine_client_streams t1 t2 =
  let map =
    StreamMap.union
      (fun _ (stream1 : c_stream) (stream2 : c_stream) ->
        let flow = Flow_control.max stream1.flow stream2.flow in
        match (stream1.state, stream2.state) with
        | Open (AwaitingResponse _, _), Open (BodyStream _, _)
        | ( HalfClosed (Local (AwaitingResponse _)),
            HalfClosed (Local (BodyStream _)) ) ->
            Some { stream2 with flow }
        | Open (BodyStream _, _), Open (AwaitingResponse _, _)
        | ( HalfClosed (Local (BodyStream _)),
            HalfClosed (Local (AwaitingResponse _)) ) ->
            Some { stream1 with flow }
        | _, Idle | Closed, Open _ | Closed, HalfClosed _ ->
            Some { stream1 with flow }
        | HalfClosed (Local _r), Open (r, _w) ->
            Some { flow; state = HalfClosed (Local r) }
        | HalfClosed (Remote _w), Open (_r, w) ->
            Some { flow; state = HalfClosed (Remote w) }
        | Idle, _ | Open _, Closed | HalfClosed _, Closed ->
            Some { stream2 with flow }
        | Open (r, _w), HalfClosed (Local _r) ->
            Some { flow; state = HalfClosed (Local r) }
        | Open (_r, w), HalfClosed (Remote _w) ->
            Some { flow; state = HalfClosed (Remote w) }
        | _ -> Some { stream1 with flow })
      t1.map t2.map
  in

  {
    map;
    last_client_stream = Int32.max t1.last_client_stream t2.last_client_stream;
    last_server_stream = Int32.max t1.last_server_stream t2.last_server_stream;
  }

let flow_of_id t stream_id =
  match StreamMap.find_opt stream_id t.map with
  | None -> Flow_control.initial
  | Some stream -> stream.flow

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
      | HalfClosed (Remote (WritingResponse response_writer)) ->
          (response_writer, None, id) :: acc
      | _ -> acc)
    t.map []

(* TODO: could do GADT for such cases *)
let body_writers t =
  match t with
  | `Server t ->
      StreamMap.fold
        (fun id (v : s_stream) (acc : 'a list) ->
          match v.state with
          | Open (_, BodyStream body_writer)
          | HalfClosed (Remote (BodyStream body_writer)) ->
              (body_writer, id) :: acc
          | _ -> acc)
        t.map []
  | `Client t ->
      StreamMap.fold
        (fun id (v : c_stream) (acc : 'a list) ->
          match v.state with
          | Open (AwaitingResponse _, body_writer)
          | Open (BodyStream _, body_writer)
          | HalfClosed (Remote body_writer) ->
              (body_writer, id) :: acc
          | _ -> acc)
        t.map []

let pp_hum_generic fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "map = @[<v 2>{";
  StreamMap.iter
    (fun key value ->
      match value.Stream.state with
      | Open _ | Reserved _ | HalfClosed _ ->
          fprintf fmt "%ld -> %a;@ " key Stream.pp_hum_generic value
      | _ -> ())
    t.map;
  fprintf fmt "}@];";
  fprintf fmt "@ last_client_stream = %ld;" t.last_client_stream;
  fprintf fmt "@ last_server_stream = %ld" t.last_server_stream;
  fprintf fmt "@]}"

let pp_hum pp_readers pp_writers fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "map = @[<v 2>{";
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
  fprintf fmt "@ last_client_stream = %ld;" t.last_client_stream;
  fprintf fmt "@ last_server_stream = %ld" t.last_server_stream;
  fprintf fmt "@]}"
