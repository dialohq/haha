type client_peer = Peer.client
type server_peer = Peer.server

type (_, 'c) writers =
  | BodyWriter : 'c Body.writer -> ('peer, 'c) writers
  | WritingResponse : 'c Response.response_writer -> (server_peer, 'c) writers

type (_, 'c) readers =
  | BodyReader : 'c Body.reader -> ('peer, 'c) readers
  | AwaitingResponse : 'c Respd.handler -> (client_peer, 'c) readers

type 'context error_handler = 'context -> Error_code.t -> 'context

type ('peer, 'c) active_state =
  | Open of { readers : ('peer, 'c) readers; writers : ('peer, 'c) writers }
  | HalfClosedRemote of ('peer, 'c) writers
  | HalfClosedLocal of ('peer, 'c) readers
  | Reserved [@warning "-37"]

(* NOTE: instead of relying on a variant itself, we could do something like a "last_seen" field and make a configuratble time range of frames that are ignored on closed streams like in Rust's h2 *)
type closed = Terminating | Terminated
type inactive_state = Idle | Closed of closed

type _ t =
  | Active : {
      state : ('peer, 'c) active_state;
      id : Stream_identifier.t;
      context : 'c;
      error_handler : 'c error_handler;
      on_close : 'c -> unit;
      flow : Flow_control.t;
    }
      -> 'peer t
  | Inactive : { state : inactive_state; id : Stream_identifier.t } -> 'peer t

type 'p transition =
  'p t -> ('p t * Writer.write list, Error_code.t * string) result

let create_idle ~id = Inactive { id; state = Idle }
let create_terminated ~id = Inactive { id; state = Closed Terminated }
let is_active = function Active _ -> true | Inactive _ -> false

let is_eraseable = function
  | Inactive { state = Idle | Closed Terminated; _ } -> true
  | _ -> false

let init :
    request:Request.t ->
    Stream_identifier.t ->
    client_peer t * Writer.write list =
 fun ~request id ->
  let (Request.Request
         {
           response_handler;
           body_writer;
           error_handler;
           initial_context;
           on_close;
           _;
         } as request) =
    request
  in
  let write = Writer.request_headers id request in
  (* Writer.(write @@ window_update ~increment:Flow_control.initial_increment id); *)
  match body_writer with
  | Some body_writer ->
      ( Active
          {
            state =
              Open
                {
                  readers = AwaitingResponse response_handler;
                  writers = BodyWriter body_writer;
                };
            id;
            error_handler;
            context = initial_context;
            on_close;
            flow = Flow_control.initial;
          },
        [ write ] )
  | None ->
      ( Active
          {
            state = HalfClosedLocal (AwaitingResponse response_handler);
            id;
            error_handler;
            context = initial_context;
            on_close;
            flow = Flow_control.initial;
          },
        [ write ] )

let read_data : end_stream:bool -> Cstruct.t -> 'a transition =
 fun ~end_stream data -> function
  | Active
      ({
         state = Open { readers = BodyReader reader; writers };
         id;
         error_handler;
         on_close;
         context;
         flow;
       } as state') ->
      let flow, writes =
        Flow_control.receive_data ~id (Cstruct.length data |> Int32.of_int) flow
      in

      let new_context =
        match (end_stream, Cstruct.is_empty data) with
        | false, _ -> reader context (`Data data)
        | true, false ->
            reader (reader context (`Data data)) (`End Headers.empty)
        | true, true -> reader context (`End Headers.empty)
      in

      let stream =
        if end_stream then
          Active
            {
              state = HalfClosedRemote writers;
              id;
              error_handler;
              on_close;
              context = new_context;
              flow;
            }
        else Active { state' with flow; context = new_context }
      in

      Ok (stream, writes)
  | Active
      ({
         state = HalfClosedLocal (BodyReader reader);
         id;
         on_close;
         context;
         flow;
         _;
       } as state') ->
      let flow, writes =
        Flow_control.receive_data ~id (Cstruct.length data |> Int32.of_int) flow
      in

      let new_context =
        match (end_stream, Cstruct.is_empty data) with
        | false, _ -> reader context (`Data data)
        | true, false ->
            reader (reader context (`Data data)) (`End Headers.empty)
        | true, true -> reader context (`End Headers.empty)
      in

      let stream =
        if end_stream then (
          on_close new_context;
          Inactive { state = Closed Terminating; id })
        else Active { state' with flow; context = new_context }
      in

      Ok (stream, writes)
  | Active { state = Reserved; id; _ } ->
      Error
        ( ProtocolError,
          Format.asprintf
            "DATA frame received on reserved stream. Stream ID %li" id )
  | Active { id; error_handler; on_close; context; _ } ->
      let final_context = error_handler context StreamClosed in
      on_close final_context;

      let write = Writer.rst_stream id StreamClosed in
      Ok (Inactive { state = Closed Terminating; id }, [ write ])
  | Inactive { state = Idle; id } ->
      Error
        ( ProtocolError,
          Format.asprintf "DATA frame received on closed stream! Stream ID %li"
            id )
  | Inactive { state = Closed Terminating; _ } as stream -> Ok (stream, [])
  | Inactive { state = Closed Terminated; id; _ } ->
      Error
        ( StreamClosed,
          Format.asprintf "DATA frame received on closed stream! Stream ID %li"
            id )

let receive_trailers : Headers.t -> 'a transition =
 fun headers -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok (stream, [])
  | Active
      ({ state = Open { readers = BodyReader reader; writers }; context; _ } as
       state) ->
      let new_context = reader context (`End headers) in

      Ok
        ( Active
            {
              state with
              context = new_context;
              state = HalfClosedRemote writers;
            },
          [] )
  | Active
      { state = HalfClosedLocal (BodyReader reader); id; on_close; context; _ }
    ->
      let new_context = reader context (`End headers) in

      on_close new_context;
      Ok (Inactive { state = Closed Terminated; id }, [])
  | Inactive { state = Idle; id } ->
      Error
        ( ProtocolError,
          Format.asprintf "HEADERS frame received on idle stream! Stream ID %li"
            id )
  | Inactive { state = Closed Terminated; _ } ->
      Error (StreamClosed, "HEADERS received on a closed stream")
  | Active
      {
        state = Reserved | HalfClosedRemote _;
        id;
        error_handler;
        context;
        on_close;
        _;
      } ->
      let final_context = error_handler context StreamClosed in
      on_close final_context;

      let write = Writer.rst_stream id StreamClosed in
      Ok (Inactive { state = Closed Terminating; id }, [ write ])
  | Active
      {
        state = Open _ | HalfClosedLocal _;
        id;
        error_handler;
        context;
        on_close;
        _;
      } ->
      let final_context = error_handler context ProtocolError in
      on_close final_context;

      let write = Writer.rst_stream id ProtocolError in
      Ok (Inactive { state = Closed Terminating; id }, [ write ])

let receive_request :
    can_open:(unit -> bool) ->
    request_handler:Reqd.handler ->
    end_stream:bool ->
    Reqd.t ->
    server_peer transition =
 fun ~can_open ~request_handler ~end_stream reqd -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok (stream, [])
  | Inactive { state = Idle; id } ->
      if can_open () then
        let (Reqd.ReqdHandle
               {
                 body_reader = reader;
                 response_writer;
                 error_handler;
                 on_close;
                 context;
               }) =
          request_handler reqd
        in

        let new_stream_state : server_peer t =
          if end_stream then
            Active
              {
                state = HalfClosedRemote (WritingResponse response_writer);
                id;
                error_handler;
                on_close;
                context;
                flow = Flow_control.initial;
              }
          else
            Active
              {
                state =
                  Open
                    {
                      readers = BodyReader reader;
                      writers = WritingResponse response_writer;
                    };
                id;
                error_handler;
                on_close;
                context;
                flow = Flow_control.initial;
              }
        in

        Ok (new_stream_state, [])
      else Error (ProtocolError, "MAX_CONCURRENT_STREAMS setting reached")
  | Active
      {
        state = Open _ | HalfClosedLocal _;
        id;
        context;
        on_close;
        error_handler;
        _;
      } ->
      let final_context = error_handler context ProtocolError in
      on_close final_context;

      let write = Writer.rst_stream id ProtocolError in
      Ok (Inactive { state = Closed Terminating; id }, [ write ])
  | Active { state = Reserved; _ } ->
      Error (ProtocolError, "HEADERS received on reserved stream")
  | Active { state = HalfClosedRemote _; _ }
  | Inactive { state = Closed Terminated; _ } ->
      Error (StreamClosed, "HEADERS received on closed stream")

let receive_response :
    respd:Respd.t -> end_stream:bool -> client_peer transition =
 fun ~respd ~end_stream -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok (stream, [])
  | Active
      ({
         state = Open { readers = AwaitingResponse response_handler; _ };
         context;
         _;
       } as s)
    when not (Respd.is_final respd) ->
      let _body_reader, context = response_handler context respd in

      Ok (Active { s with context }, [])
  | Active
      ({
         state = HalfClosedLocal (AwaitingResponse response_handler);
         context;
         _;
       } as s)
    when not (Respd.is_final respd) ->
      let _body_reader, context = response_handler context respd in

      Ok (Active { s with context }, [])
  | Active
      {
        state =
          Open
            {
              readers = AwaitingResponse response_handler;
              writers = BodyWriter body_writer;
            };
        id;
        error_handler;
        on_close;
        context;
        flow;
      } ->
      let body_reader, context = response_handler context respd in

      let result' : client_peer t * Writer.write list =
        match (body_reader, end_stream) with
        | None, _ ->
            (* NOTE: notice this is different than normal stream error, we don't use error_handler here *)
            on_close context;

            let write = Writer.rst_stream id NoError in
            (Inactive { state = Closed Terminating; id }, [ write ])
        | Some _, true ->
            ( Active
                {
                  state = HalfClosedRemote (BodyWriter body_writer);
                  id;
                  error_handler;
                  on_close;
                  context;
                  flow;
                },
              [] )
        | Some body_reader, false ->
            ( Active
                {
                  state =
                    Open
                      {
                        readers = BodyReader body_reader;
                        writers = BodyWriter body_writer;
                      };
                  id;
                  error_handler;
                  on_close;
                  context;
                  flow;
                },
              [] )
      in

      Ok result'
  | Active
      {
        state = HalfClosedLocal (AwaitingResponse response_handler);
        id;
        error_handler;
        context;
        on_close;
        flow;
      } ->
      let body_reader, context = response_handler context respd in

      let result' : client_peer t * Writer.write list =
        match (end_stream, body_reader) with
        | false, None ->
            (* NOTE: notice this is different than normal stream error, we don't use error_handler here *)
            on_close context;

            let write = Writer.rst_stream id NoError in
            (Inactive { state = Closed Terminating; id }, [ write ])
        | false, Some body_reader ->
            ( Active
                {
                  state = HalfClosedLocal (BodyReader body_reader);
                  id;
                  error_handler;
                  on_close;
                  context;
                  flow;
                },
              [] )
        | true, _ ->
            on_close context;
            (Inactive { state = Closed Terminated; id }, [])
      in

      Ok result'
  | Active
      {
        state =
          Open { readers = BodyReader _; _ } | HalfClosedLocal (BodyReader _);
        error_handler;
        on_close;
        context;
        id;
        _;
      } ->
      let final_context = error_handler context ProtocolError in
      on_close final_context;

      let write = Writer.rst_stream id ProtocolError in
      Ok (Inactive { state = Closed Terminating; id }, [ write ])
  | Inactive { state = Idle; _ } ->
      Error (ProtocolError, "unexpected HEADERS response on idle stream")
  | Active { state = Reserved; _ } ->
      Error (ProtocolError, "HEADERS received on reserved stream")
  | Active { state = HalfClosedRemote _; _ }
  | Inactive { state = Closed Terminated; _ } ->
      Error (StreamClosed, "HEADERS received on closed stream")

let receive_headers_server :
    request_handler:Reqd.handler ->
    end_stream:bool ->
    Headers.t ->
    server_peer transition =
 fun ~request_handler ~end_stream headers ->
  let pseudo_validation = Headers.Pseudo.validate headers in

  match (end_stream, pseudo_validation) with
  | _, Invalid _ | false, NotPresent | _, Valid (Response _) -> (
      function
      | Inactive stream ->
          Ok (Inactive { stream with state = Closed Terminated }, [])
      | Active s ->
          let final_context = s.error_handler s.context ProtocolError in
          s.on_close final_context;

          let write = Writer.rst_stream s.id ProtocolError in
          Ok (Inactive { state = Closed Terminating; id = s.id }, [ write ]))
  | true, NotPresent -> receive_trailers headers
  | end_stream, Valid (Request pseudo) ->
      let reqd =
        {
          Reqd.meth = Method.of_string pseudo.meth;
          path = pseudo.path;
          authority = pseudo.authority;
          scheme = pseudo.scheme;
          headers = Headers.filter_out_pseudo headers;
        }
      in

      (* TODO: pass can_open *)
      receive_request
        ~can_open:(fun () -> true)
        ~request_handler ~end_stream reqd

let receive_headers_client :
    end_stream:bool -> Headers.t -> client_peer transition =
 fun ~end_stream headers ->
  let pseudo_validation = Headers.Pseudo.validate headers in

  match (end_stream, pseudo_validation) with
  | _, Invalid _ | false, NotPresent | _, Valid (Request _) -> (
      function
      | Inactive stream ->
          Ok (Inactive { stream with state = Closed Terminated }, [])
      | Active s ->
          let final_context = s.error_handler s.context ProtocolError in
          s.on_close final_context;

          let write = Writer.rst_stream s.id ProtocolError in
          Ok (Inactive { state = Closed Terminating; id = s.id }, [ write ]))
  | true, NotPresent -> receive_trailers headers
  | end_stream, Valid (Response pseudo) ->
      let respd =
        Respd.create
          (Status.of_code pseudo.status)
          (Headers.filter_out_pseudo headers)
      in
      receive_response ~respd ~end_stream

let receive_rst : Error_code.t -> 'a transition =
 fun code -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok (stream, [])
  | Inactive { state = Idle; _ } ->
      Error (ProtocolError, "RST_STREAM received on a idle stream")
  | Inactive { state = Closed Terminated; _ } ->
      Error (StreamClosed, "RST_STREAM received on a closed stream!")
  | Active { error_handler; on_close; context; id; _ } ->
      let final_context = error_handler context code in
      on_close final_context;

      (* NOTE: notice we're not writing here *)
      Ok (Inactive { state = Closed Terminating; id }, [])

let writer_payload_writes :
    id:Stream_identifier.t -> Body.writer_payload -> Writer.write list =
 fun ~id ->
  let max_frame_size = 16000 in
  function
  | `Data cs_list ->
      let distributed = Util.split_cstructs cs_list max_frame_size in
      let writes =
        List.map (fun cs_list -> Writer.data id cs_list) distributed
      in

      writes
  | `End (Some cs_list, trailers) ->
      let send_trailers = Headers.length trailers > 0 in
      let distributed = Util.split_cstructs cs_list max_frame_size in
      let data_writes =
        List.mapi
          (fun i cs_list ->
            Writer.data
              ~end_stream:
                ((not send_trailers) && i = List.length distributed - 1)
              id cs_list)
          distributed
      in

      let writes =
        if send_trailers then data_writes @ [ Writer.trailers id trailers ]
        else data_writes
      in

      writes
  | `End (None, trailers) ->
      let send_trailers = Headers.length trailers > 0 in
      let write =
        if send_trailers then Writer.trailers id trailers
        else Writer.data ~end_stream:true id [ Cstruct.empty ]
      in

      [ write ]

let get_event (type p) : p t -> (unit -> p t * Writer.write list) option =
  function
  | Active
      ({
         state = Open { writers = BodyWriter body_writer; readers };
         context;
         id;
         _;
       } as stream) ->
      Some
        (fun () ->
          let { Body.payload; context } = body_writer context in
          let writes = writer_payload_writes ~id payload in
          match payload with
          | `End _ ->
              ( Active { stream with context; state = HalfClosedLocal readers },
                writes )
          | `Data _ -> (Active { stream with context }, writes))
  | Active
      ({
         state = HalfClosedRemote (BodyWriter body_writer);
         context;
         id;
         on_close;
         _;
       } as stream) ->
      Some
        (fun () ->
          let { Body.payload; context } = body_writer context in
          let writes = writer_payload_writes ~id payload in
          match payload with
          | `End _ ->
              on_close context;
              (Inactive { state = Closed Terminating; id }, writes)
          | `Data _ -> (Active { stream with context }, writes))
  | Active
      ({
         state = Open { writers = WritingResponse response_writer; readers };
         id;
         _;
       } as stream) ->
      Some
        (fun () ->
          let response = response_writer () in
          let write = Writer.response_headers id response in
          match response with
          | `Final { body_writer = Some body_writer; _ } ->
              (* window_update id ~increment:Flow_control.initial_increment writer; *)
              ( Active
                  {
                    stream with
                    state = Open { writers = BodyWriter body_writer; readers };
                  },
                [ write ] )
          | `Final { body_writer = None; _ } ->
              (* window_update id ~increment:Flow_control.initial_increment writer; *)
              (Active { stream with state = HalfClosedLocal readers }, [ write ])
          | `Interim _ -> (Active stream, [ write ]))
  | Active
      ({
         state = HalfClosedRemote (WritingResponse response_writer);
         id;
         on_close;
         context;
         _;
       } as stream) ->
      Some
        (fun () ->
          let response = response_writer () in
          let write = Writer.response_headers id response in
          match response with
          | `Final { body_writer = Some body_writer; _ } ->
              (* window_update id ~increment:Flow_control.initial_increment writer; *)
              ( Active
                  {
                    stream with
                    state = HalfClosedRemote (BodyWriter body_writer);
                  },
                [ write ] )
          | `Final { body_writer = None; _ } ->
              (* window_update id ~increment:Flow_control.initial_increment writer; *)
              on_close context;
              (Inactive { state = Closed Terminating; id }, [ write ])
          | `Interim _ -> (Active stream, [ write ]))
  | _ -> None
