type client_peer = private Client [@warning "-37"]
type server_peer = private Server [@warning "-37"]

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

type 'peer t =
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

type 'p transition = 'p t -> ('p t, Error_code.t * string) result

let create_idle ~id = Inactive { id; state = Idle }
let create_terminated ~id = Inactive { id; state = Closed Terminated }

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
      let flow =
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

      Ok stream
  | Active
      ({
         state = HalfClosedLocal (BodyReader reader);
         id;
         on_close;
         context;
         flow;
         _;
       } as state') ->
      let flow =
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

      Ok stream
  | Active { state = Reserved; id; _ } ->
      Error
        ( ProtocolError,
          Format.asprintf
            "DATA frame received on reserved stream. Stream ID %li" id )
  | Active { id; error_handler; on_close; context; _ } ->
      let final_context = error_handler context StreamClosed in
      on_close final_context;

      Writer.(write @@ Writer.rst_stream id StreamClosed);
      Ok (Inactive { state = Closed Terminating; id })
  | Inactive { state = Idle; id } ->
      Error
        ( ProtocolError,
          Format.asprintf "DATA frame received on closed stream! Stream ID %li"
            id )
  | Inactive { state = Closed Terminating; _ } as stream -> Ok stream
  | Inactive { state = Closed Terminated; id; _ } ->
      Error
        ( StreamClosed,
          Format.asprintf "DATA frame received on closed stream! Stream ID %li"
            id )

let receive_trailers : Headers.t -> 'a transition =
 fun headers -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok stream
  | Active
      ({ state = Open { readers = BodyReader reader; writers }; context; _ } as
       state) ->
      let new_context = reader context (`End headers) in

      Ok
        (Active
           {
             state with
             context = new_context;
             state = HalfClosedRemote writers;
           })
  | Active
      { state = HalfClosedLocal (BodyReader reader); id; on_close; context; _ }
    ->
      let new_context = reader context (`End headers) in

      on_close new_context;
      Ok (Inactive { state = Closed Terminated; id })
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

      Writer.(write @@ rst_stream id StreamClosed);
      Ok (Inactive { state = Closed Terminating; id })
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

      Writer.(write @@ rst_stream id ProtocolError);
      Ok (Inactive { state = Closed Terminating; id })

let receive_request :
    can_open:(unit -> bool) ->
    request_handler:Reqd.handler ->
    end_stream:bool ->
    Headers.t ->
    Headers.Pseudo.request_pseudos ->
    server_peer transition =
 fun ~can_open ~request_handler ~end_stream headers pseudo -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok stream
  | Inactive { state = Idle; id } ->
      if can_open () then
        let reqd =
          {
            Reqd.meth = Method.of_string pseudo.meth;
            path = pseudo.path;
            authority = pseudo.authority;
            scheme = pseudo.scheme;
            headers;
          }
        in

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

        Ok new_stream_state
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

      Writer.(write @@ rst_stream id ProtocolError);
      Ok (Inactive { state = Closed Terminating; id })
  | Active { state = Reserved; _ } ->
      Error (ProtocolError, "HEADERS received on reserved stream")
  | Active { state = HalfClosedRemote _; _ }
  | Inactive { state = Closed Terminated; _ } ->
      Error (StreamClosed, "HEADERS received on closed stream")

let receive_response :
    respd:Respd.t -> end_stream:bool -> client_peer transition =
 fun ~respd ~end_stream -> function
  | Inactive { state = Closed Terminating; _ } as stream -> Ok stream
  | Active
      ({
         state = Open { readers = AwaitingResponse response_handler; _ };
         context;
         _;
       } as s)
    when not (Respd.is_final respd) ->
      let _body_reader, context = response_handler context respd in

      Ok (Active { s with context })
  | Active
      ({
         state = HalfClosedLocal (AwaitingResponse response_handler);
         context;
         _;
       } as s)
    when not (Respd.is_final respd) ->
      let _body_reader, context = response_handler context respd in

      Ok (Active { s with context })
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

      let new_stream_state : client_peer t =
        match (body_reader, end_stream) with
        | None, _ ->
            (* NOTE: notice this is different than normal stream error, we don't use error_handler here *)
            on_close context;

            Writer.(write @@ rst_stream id NoError);
            Inactive { state = Closed Terminating; id }
        | Some _, true ->
            Active
              {
                state = HalfClosedRemote (BodyWriter body_writer);
                id;
                error_handler;
                on_close;
                context;
                flow;
              }
        | Some body_reader, false ->
            Active
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
              }
      in

      Ok new_stream_state
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

      let new_stream_state : client_peer t =
        match (end_stream, body_reader) with
        | false, None ->
            (* NOTE: notice this is different than normal stream error, we don't use error_handler here *)
            on_close context;

            Writer.(write @@ rst_stream id NoError);
            Inactive { state = Closed Terminating; id }
        | false, Some body_reader ->
            Active
              {
                state = HalfClosedLocal (BodyReader body_reader);
                id;
                error_handler;
                on_close;
                context;
                flow;
              }
        | true, _ ->
            on_close context;
            Inactive { state = Closed Terminated; id }
      in

      Ok new_stream_state
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

      Writer.(write @@ rst_stream id ProtocolError);
      Ok (Inactive { state = Closed Terminating; id })
  | Inactive { state = Idle; _ } ->
      Error (ProtocolError, "unexpected HEADERS response on idle stream")
  | Active { state = Reserved; _ } ->
      Error (ProtocolError, "HEADERS received on reserved stream")
  | Active { state = HalfClosedRemote _; _ }
  | Inactive { state = Closed Terminated; _ } ->
      Error (StreamClosed, "HEADERS received on closed stream")

(* 

   To transition from two receive_headers_* functions to one, a good idea would be to pass a module called smth like `Peer` which would include a minimal functionalities that are peer-specific.

   In this case it would probobly be a function that validates the pseudo headers which are different for each peer.

   The `client_peer` and `server_peer` at the top are pretty good for peer specific states, althought this could be abstracted in some other way as well.

*)

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
          Ok (Inactive { stream with state = Closed Terminated })
      | Active s ->
          let final_context = s.error_handler s.context ProtocolError in
          s.on_close final_context;

          Writer.(write @@ rst_stream s.id ProtocolError);
          Ok (Inactive { state = Closed Terminating; id = s.id }))
  | true, NotPresent -> receive_trailers headers
  | end_stream, Valid (Request pseudo) ->
      (* TODO: pass can_open *)
      receive_request
        ~can_open:(fun () -> true)
        ~request_handler ~end_stream headers pseudo

let receive_headers_client :
    end_stream:bool -> Headers.t -> client_peer transition =
 fun ~end_stream headers ->
  let pseudo_validation = Headers.Pseudo.validate headers in

  match (end_stream, pseudo_validation) with
  | _, Invalid _ | false, NotPresent | _, Valid (Request _) -> (
      function
      | Inactive stream ->
          Ok (Inactive { stream with state = Closed Terminated })
      | Active s ->
          let final_context = s.error_handler s.context ProtocolError in
          s.on_close final_context;

          Writer.(write @@ rst_stream s.id ProtocolError);
          Ok (Inactive { state = Closed Terminating; id = s.id }))
  | true, NotPresent -> receive_trailers headers
  | end_stream, Valid (Response pseudo) ->
      let respd =
        Respd.create
          (Status.of_code pseudo.status)
          (Headers.filter_out_pseudo headers)
      in
      receive_response ~respd ~end_stream
