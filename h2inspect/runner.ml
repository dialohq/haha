open H2kit
module Serializers = Serializers.Make (Buf_write)

exception Fail of string

type state = {
  next_element : unit -> Element.t;
  writer : Writer.t;
  mutable ignore : Ignore.t;
}

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
 fun f { next_element; ignore; _ } ->
  let rec aux () =
    let el = next_element () in
    if ignore el then aux () else f el
  in

  aux ()

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

let print_wrapped_sentence ~indent sentence =
  let open Format in
  set_margin 100;

  pp_open_hovbox std_formatter indent;

  let words = String.split_on_char ' ' sentence in

  List.iter
    (fun word ->
      pp_print_string std_formatter word;
      pp_print_space std_formatter ())
    words;

  pp_close_box std_formatter ();
  pp_print_newline std_formatter ()

type test = {
  label : string;
  runner : unit t;
  description : (string, Format.formatter, unit, string) format4 option;
}

type action = GET of string | POST of string
type test_group = { label : string; tests : test list; assume : action list }

let run_test :
    next_element:(unit -> Element.t) ->
    writer:Buf_write.t ->
    int ->
    int ->
    test ->
    unit =
 fun ~next_element ~writer:writer' j i { runner; label; description } ->
  let writer =
    Writer.create ~writer:writer' ~hpack:(Hpack.Encoder.create 1000)
  in
  let state = { next_element; writer; ignore = Ignore.nothing } in
  match
    try
      runner state;
      None
    with Fail msg -> Some msg
  with
  | None ->
      Ocolor_format.printf "%i.%i. @{<grey>%s@} - @{<green>@{<bold>Pass@}@}@." j
        (i + 1) label
  | Some msg ->
      let open Serializers in
      write_goaway_frame ~debug_data:(Cstruct.of_string msg) 0l ProtocolError
        writer';
      Buf_write.flush writer';
      Ocolor_format.printf "%i.%i. @{<grey>%s@} - @{<red>@{<bold>Fail:@} %s@}@."
        j (i + 1) label msg;
      description
      |> Option.iter @@ fun description ->
         let desc =
           Ocolor_format.asprintf "  @{<grey>@{<bold>> %s@}@}@."
             (Ocolor_format.asprintf description)
         in
         print_wrapped_sentence ~indent:6 desc

open Eio

let run_groups :
    sw:Switch.t ->
    net:[> _ Net.ty ] Resource.t ->
    clock:float Time.clock_ty Resource.t ->
    (int * test_group) list ->
    unit =
 fun ~sw ~net ~clock ->
  List.iter @@ fun (port, { tests; _ }) ->
  (* Ocolor_format.printf "%i. @{<bold>%s@}@." (i + 1) label; *)
  let server_socket =
    Net.listen ~sw ~backlog:10 ~reuse_addr:true net
      (`Tcp (Net.Ipaddr.V4.any, port))
  in

  Fiber.fork ~sw @@ fun () ->
  Switch.run @@ fun sw ->
  let rec accept j = function
    | [] -> ()
    | test :: rest ->
        Net.accept_fork ~sw ~on_error:ignore server_socket (fun flow _ ->
            Buf_write.with_flow flow @@ fun writer ->
            Reader.run ~sw ~clock flow @@ fun next_element ->
            run_test ~writer ~next_element port j test);
        accept (j + 1) rest
  in

  accept 0 tests
