open H2kit
module Serializers = Serializers.Make (Buf_write)
open Format

type state = {
  next_element : unit -> Element.t;
  writer : Buf_write.t;
  hpack_encoder : Hpack.Encoder.t;
  mutable ignore : Element.t -> bool;
}

type verdict = Pass | Fail of string
type t = state -> verdict

let ( >> ) : t -> t -> t =
 fun t1 t2 state -> match t1 state with Pass -> t2 state | x -> x

let ( *> ) : t -> t -> t =
 fun t1 t2 state ->
  ignore (t1 state);
  t2 state

let ( <* ) : t -> t -> t =
 fun t1 t2 state ->
  let v = t1 state in
  ignore (t2 state);
  v

let with_writer : (Buf_write.t -> unit) -> t =
 fun f { writer; _ } ->
  f writer;
  Buf_write.flush writer;
  Pass

let with_hpack : (Buf_write.t -> Hpack.Encoder.t -> unit) -> t =
 fun f { writer; hpack_encoder; _ } ->
  f writer hpack_encoder;
  Buf_write.flush writer;
  Pass

let with_ignore : (Element.t -> verdict) -> t =
 fun f { next_element; ignore; _ } ->
  let rec aux () =
    let el = next_element () in
    match (f el, ignore el) with
    | Pass, _ -> Pass
    | fail, false -> fail
    | _, true -> aux ()
  in
  aux ()

module Ignore = struct
  let ( + ) t1 t2 = fun el -> t1 el || t2 el
  let default : Element.t -> bool = fun _ -> false

  let reset : t =
   fun t ->
    t.ignore <- default;
    Pass

  let window_update : t =
   fun t ->
    let ig = function
      | Element.Frame { frame_payload = WindowUpdate _; _ } -> true
      | _ -> false
    in
    t.ignore <- t.ignore + ig;
    Pass

  let stream_frames : t =
   fun t ->
    let ig = function
      | Element.Frame
          {
            frame_payload =
              Headers _ | Data _ | RSTStream _ | PushPromise _ | Continuation _;
            _;
          } ->
          true
      | _ -> false
    in
    t.ignore <- t.ignore + ig;
    Pass
end

module Expect = struct
  let magic : t =
    with_ignore @@ function
    | Magic -> Pass
    | _ -> Fail "Expected preface magic string"

  let settings : t =
    with_ignore @@ function
    | Frame { frame_payload = Settings _; frame_header = { flags; _ } } ->
        if Flags.test_empty flags then Pass
        else Fail "Expected SETTINGS frame without any flags set"
    | _ -> Fail "Expected SETTINGS frame"

  let settings_ack : t =
    with_ignore @@ function
    | Frame { frame_payload = Settings _; frame_header = { flags; _ } } ->
        if Flags.test_ack flags then Pass
        else Fail "Expected SETTINGS frame with ACK flag set"
    | _ -> Fail "Expected SETTINGS frame with ACK flag set"

  let ping : t =
    with_ignore @@ function
    | Frame { frame_payload = Ping cs; _ } ->
        if Cstruct.to_string cs = "12345678" then Pass
        else Fail "Expected PING frame with payload \"12345678\""
    | _ -> Fail "Expected PING frame"

  let window_update : t =
    with_ignore @@ function
    | Frame { frame_payload = WindowUpdate _; _ } -> Pass
    | _ -> Fail "Expected WINDOW_UPDATE frame"

  let goaway : t =
    with_ignore @@ function
    | Frame { frame_payload = GoAway _; _ } -> Pass
    | _ -> Fail "Expected GOAWAY frame"

  let headers : t =
    with_ignore @@ function
    | Frame { frame_payload = Headers _; _ } -> Pass
    | _ -> Fail "Expected HEADERS frame"

  let conn_error : Error_code.t -> t =
   fun code ->
    with_ignore @@ function
    | Frame { frame_payload = GoAway (_, received_code, _); _ }
      when code = received_code ->
        Pass
    | _ ->
        Fail
          (Format.asprintf "Expected GOAWAY frame with error code %s"
             (Error_code.to_string code))

  let eof : t =
    with_ignore @@ function
    | EOF -> Pass
    | _ -> Fail "Expected TCP connection to close"
end

module Write = struct
  open Serializers

  let settings settings =
    with_writer @@ write_settings_frame settings (create_frame_info 0l)

  let settings_ack =
    with_writer
    @@ write_settings_frame []
         (create_frame_info ~flags:H2kit.Flags.(default_flags |> set_ack) 0l)

  let custom_header_settings ?(flags = Flags.default_flags) ?(len = 6)
      ?(id = 0l) () =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      { flags; payload_length = len; stream_id = id; frame_type = Settings }
      w;
    LowLevel.write_settings_frame_payload [ EnablePush 0 ] w

  let unknown_setting =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      {
        flags = Flags.default_flags;
        payload_length = 12;
        stream_id = 0l;
        frame_type = Settings;
      }
      w;
    LowLevel.write_settings_frame_payload [ EnablePush 0 ] w;
    Buf_write.BE.write_uint16 w 7;
    Buf_write.BE.write_uint32 w 10l

  let ping =
    with_writer
    @@ write_ping_frame (Cstruct.of_string "12345678") (create_frame_info 0l)

  let custom_header_ping ?(flags = Flags.default_flags) ?(len = 8) ?(id = 0l) ()
      =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      { flags; payload_length = len; stream_id = id; frame_type = Ping }
      w;
    Buf_write.schedule_cstruct w (Cstruct.of_string "12345678")

  let goaway code = with_writer @@ write_goaway_frame 0l code

  let custom_header_goaway ?(flags = Flags.default_flags) ?(len = 0) ?(id = 0l)
      () =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      { flags; payload_length = len; stream_id = id; frame_type = GoAway }
      w;
    LowLevel.write_goaway_frame_payload 0l NoError w

  let window_update ?(flags = Flags.default_flags) ?(len = 4) ?(id = 0l) incr =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      { flags; payload_length = len; stream_id = id; frame_type = WindowUpdate }
      w;
    LowLevel.write_window_update_frame_payload incr w

  let unknown =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      {
        flags = Flags.default_flags;
        stream_id = 0l;
        frame_type = Unknown 20;
        payload_length = 8;
      }
      w;
    Buf_write.schedule_cstruct w (Cstruct.of_string "12345678")

  let headers
      ?(flags = Flags.(default_flags |> set_end_header |> set_end_stream)) ?len
      ?(id = 1l) ?pad_len headers =
    with_hpack @@ fun w encoder ->
    let tmp_faraday = Faraday.create 1_000 in

    (match headers with
    | `Block { Cstruct.off; len; buffer } ->
        Faraday.write_bigstring tmp_faraday ~off ~len buffer
    | `List headers ->
        let headers = Headers.of_list headers in
        Headers.iter
          (fun (name, value) ->
            Hpack.Encoder.encode_header encoder tmp_faraday
              { Hpack.name; value; sensitive = false })
          headers);

    let length = Faraday.pending_bytes tmp_faraday in

    LowLevel.write_frame_header
      {
        flags;
        payload_length = Option.value ~default:length len;
        stream_id = id;
        frame_type = Headers;
      }
      w;
    Option.iter (Buf_write.uint8 w) pad_len;
    Buf_write.schedule_bigstring w (Faraday.serialize_to_bigstring tmp_faraday);
    Option.iter
      (fun pad_len ->
        let padding = Cstruct.create pad_len in
        Cstruct.memset padding 0;
        Buf_write.cstruct w padding)
      pad_len

  let rst_stream ?(flags = Flags.default_flags) ?(len = 4) ?(id = 1l) code =
    with_writer @@ fun w ->
    LowLevel.write_frame_header
      { flags; payload_length = len; stream_id = id; frame_type = RSTStream }
      w;
    LowLevel.write_rst_stream_frame_payload code w
end

module Sets = struct
  let preface =
    Expect.magic >> Expect.settings >> Write.settings [] >> Write.settings_ack
    >> Expect.settings_ack

  let conn_only = Ignore.window_update >> Ignore.stream_frames
end

module I = Ignore
module E = Expect
module W = Write
module S = Sets

let print_wrapped_sentence ~indent sentence =
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
  runner : t;
  description : (string, Format.formatter, unit, string) format4 option;
}

type test_group = { label : string; tests : test list }

let run_test :
    next_element:(unit -> Element.t) ->
    writer:Buf_write.t ->
    int ->
    test ->
    unit =
 fun ~next_element ~writer i { runner; label; description } ->
  let state =
    {
      next_element;
      writer;
      ignore = Ignore.default;
      hpack_encoder = Hpack.Encoder.create 1000;
    }
  in
  match runner state with
  | Pass ->
      Ocolor_format.printf "  %i. @{<grey>%s@} - @{<green>@{<bold>Pass@}@}@."
        (i + 1) label
  | Fail msg ->
      let open Serializers in
      write_goaway_frame ~debug_data:(Cstruct.of_string msg) 0l ProtocolError
        writer;
      Buf_write.flush writer;
      Ocolor_format.printf "  %i. @{<grey>%s@} - @{<red>@{<bold>Fail:@} %s@}@."
        (i + 1) label msg;
      description
      |> Option.iter @@ fun description ->
         let desc =
           Ocolor_format.asprintf "    @{<grey>@{<bold>> %s@}@}@."
             (Ocolor_format.asprintf description)
         in
         print_wrapped_sentence ~indent:6 desc

open Eio

let run_groups :
    sw:Switch.t ->
    net:[> _ Net.ty ] Resource.t ->
    clock:float Time.clock_ty Resource.t ->
    test_group list ->
    unit =
 fun ~sw ~net ~clock ->
  List.iteri @@ fun i { label; tests } ->
  Ocolor_format.printf "%i. @{<bold>%s@}@." (i + 1) label;
  let server_socket =
    Net.listen ~sw ~backlog:10 ~reuse_addr:true net
      (`Tcp (Net.Ipaddr.V4.any, 8000 + i))
  in

  Switch.run @@ fun sw ->
  let rec accept i = function
    | [] -> ()
    | test :: rest ->
        Net.accept_fork ~sw ~on_error:ignore server_socket (fun flow _ ->
            Buf_write.with_flow flow @@ fun writer ->
            Reader.run ~sw ~clock flow @@ fun next_element ->
            run_test ~writer ~next_element i test);
        accept (i + 1) rest
  in

  accept 0 tests
