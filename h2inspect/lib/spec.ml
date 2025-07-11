open H2kit
module Serializers = Serializers.Make (Buf_write)

exception Fail of string

type state = {
  next_element : unit -> Element.t;
  writer : Writer.t;
  mutable ignore : Ignore.t;
  mutable buffered : Element.t option;
}

let make_state ~next_element ~writer =
  { next_element; writer; ignore = Ignore.nothing; buffered = None }

type 'a t = state -> 'a

let ( *> ) : _ t -> _ t -> _ t =
 fun t1 t2 state ->
  ignore (t1 state);
  t2 state

let ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t =
 fun t f state -> (f (t state)) state

let ( let* ) = ( >>= )
let ( >>| ) : 'a t -> ('a -> 'b) -> 'b t = fun t f state -> f (t state)

let ( +> ) : (Writer.t -> unit) -> 'a t -> 'a t =
 fun f t state ->
  f state.writer;
  t state

let ( <+ ) : 'a t -> (Writer.t -> unit) -> 'a t =
 fun t f state ->
  let v = t state in
  f state.writer;
  v

let ( ++ ) : (Writer.t -> unit) -> (Writer.t -> unit) -> Writer.t -> unit =
 fun f1 f2 w ->
  f1 w;
  f2 w

let return : 'a -> 'a t = fun x _ -> x
let fail : string -> _ t = fun msg _ -> raise (Fail msg)

let register_ignore : Ignore.t -> unit t =
 fun ign state ->
  state.ignore <- Ignore.(state.ignore + ign);
  ()

let reset_ignore : unit t =
 fun state ->
  state.ignore <- Ignore.nothing;
  ()

let with_ignore : (Element.t -> 'a) -> 'a t =
 fun f state ->
  let rec aux () =
    let el =
      match state.buffered with
      | None -> state.next_element ()
      | Some x ->
          state.buffered <- None;
          x
    in
    if state.ignore el then aux () else f el
  in

  aux ()

let many : 'a t -> 'a list t =
 fun t state ->
  let rec aux acc =
    let el = state.next_element () in
    match el with
    | Timeout -> List.rev acc
    | el -> (
        state.buffered <- Some el;

        match try Some (t state) with Fail _ -> None with
        | Some v -> aux (v :: acc)
        | None ->
            state.buffered <- Some el;
            List.rev acc)
  in
  aux []

let raise_with_expected : string -> Element.t -> _ =
 fun msg el -> raise (Fail (Element.make_msg msg el))

let frame_header : Frame.frame_header t =
  with_ignore @@ function
  | Frame { frame_header; _ } -> frame_header
  | el -> raise_with_expected "any frame" el

let magic : unit t =
  with_ignore @@ function
  | Magic -> ()
  | el -> raise_with_expected "preface magic string" el

let settings : Settings.setting list t =
  with_ignore @@ function
  | Frame { frame_payload = Settings l; frame_header = { flags; _ } } as el ->
      if not (Flags.test_empty flags) then
        raise_with_expected "SETTINGS frame without any flags set" el
      else l
  | el -> raise_with_expected "Expected SETTINGS frame" el

let settings_ack : unit t =
  frame_header >>= function
  | { frame_type = Settings; flags; _ } when Flags.test_ack flags -> return ()
  | { frame_type; _ } ->
      fail
        (Format.asprintf "SETTINGS with ACK flag set but got frame type %a"
           Frame.FrameType.pp frame_type)

let ping : Cstruct.t t =
  with_ignore @@ function
  | Frame { frame_payload = Ping cs; _ } -> cs
  | el -> raise_with_expected "PING frame" el

let window_update : int32 t =
  with_ignore @@ function
  | Frame { frame_payload = WindowUpdate incre; _ } -> incre
  | el -> raise_with_expected "WINDOW_UPDATE frame" el

let goaway : (int32 * Error_code.t * Cstruct.t) t =
  with_ignore @@ function
  | Frame { frame_payload = GoAway (id, code, bs); _ } ->
      (id, code, Cstruct.of_bigarray bs)
  | el -> raise_with_expected "GOAWAY frame" el

let headers : Cstruct.t t =
  with_ignore @@ function
  | Frame { frame_payload = Headers block; _ } -> Cstruct.of_bigarray block
  | el -> raise_with_expected "HEADERS frame" el

let rst_stream : (int32 * Error_code.t) t =
  with_ignore @@ function
  | Frame { frame_payload = RSTStream code; frame_header = { stream_id; _ }; _ }
    ->
      (stream_id, code)
  | el -> raise_with_expected "RST_STREAM frame" el

let data : Cstruct.t t =
  with_ignore @@ function
  | Frame { frame_payload = Data cs; _ } -> cs
  | el -> raise_with_expected "DATA frame" el

let conn_error : Error_code.t -> unit t =
 fun code ->
  goaway >>= fun (_, code', _) ->
  if code <> code' then
    fail
      (Format.asprintf "Expected error code %s, got %s"
         (Error_code.to_string code)
         (Error_code.to_string code'))
  else return ()

let stream_error : int32 -> Error_code.t -> unit t =
 fun id code ->
  rst_stream >>= fun (id', code') ->
  match (id = id', code = code') with
  | true, true -> return ()
  | false, false ->
      fail
        (Format.asprintf
           "Expected RST_STREAM[%li] with code %s, but got RST_STREAM[%li] \
            with code %s"
           id
           (Error_code.to_string code)
           id'
           (Error_code.to_string code'))
  | true, false ->
      fail
        (Format.asprintf "Expected error code %s, got %s"
           (Error_code.to_string code)
           (Error_code.to_string code'))
  | false, true ->
      fail (Format.asprintf "Expected error on stream %li, not %li" id id')

let eof : unit t =
  with_ignore @@ function
  | EOF -> ()
  | el -> raise_with_expected "TCP connection to close" el

module Sets = struct
  let preface =
    register_ignore Ignore.(frame_type WindowUpdate)
    *> magic *> settings
    *> (Writer.settings []
       ++ Writer.settings ~flags:Flags.(default_flags |> set_ack) []
       +> settings_ack)

  let conn_only =
    preface *> register_ignore Ignore.(stream_frames + frame_type WindowUpdate)
end

module I = Ignore
module S = Sets
