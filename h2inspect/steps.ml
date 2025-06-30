open H2kit

type expect_step = Element.t -> string option
type write_step = Buf_write.t -> unit
type ignore_step = Add of (Element.t -> bool) | Reset

type step =
  | Expect of expect_step
  | Write of write_step
  | Ignore of ignore_step

module Ignore = struct
  let ( + ) t1 t2 = fun el -> t1 el || t2 el
  let deafult : Element.t -> bool = fun _ -> false
  let reset : step = Ignore Reset

  let window_update : step =
    Ignore
      (Add
         (function
         | Element.Frame { frame_payload = WindowUpdate _; _ } -> true
         | _ -> false))
end

module Expect = struct
  let magic : step =
    Expect
      (function Magic -> None | _ -> Some "Expected preface magic string")

  let settings : step =
    Expect
      (function
      | Frame { frame_payload = Settings _; frame_header = { flags; _ } } ->
          if Flags.test_empty flags then None
          else Some "Expected SETTINGS frame without any flags set"
      | _ -> Some "Expected SETTINGS frame")

  let settings_ack : step =
    Expect
      (function
      | Frame { frame_payload = Settings _; frame_header = { flags; _ } } ->
          if Flags.test_ack flags then None
          else Some "Expected SETTINGS frame with ACK flag set"
      | _ -> Some "Expected SETTINGS frame with ACK flag set")

  let ping : step =
    Expect
      (function
      | Frame { frame_payload = Ping cs; _ } ->
          if Cstruct.to_string cs = "12345678" then None
          else Some "Expected PING frame with payload \"12345678\""
      | _ -> Some "Expected PING frame")

  let window_update : step =
    Expect
      (function
      | Frame { frame_payload = WindowUpdate _; _ } -> None
      | _ -> Some "Expected WINDOW_UPDATE frame")

  let goaway : step =
    Expect
      (function
      | Frame { frame_payload = GoAway _; _ } -> None
      | _ -> Some "Expected GOAWAY frame")
end

module Write = struct
  open Serializers.Make (Buf_write)

  let settings =
    Write
      (fun bw ->
        write_settings_frame bw [] (create_frame_info 0l);
        Buf_write.flush bw)

  let settings_ack =
    Write
      (fun bw ->
        write_settings_frame bw []
          (create_frame_info ~flags:H2kit.Flags.(default_flags |> set_ack) 0l);
        Buf_write.flush bw)

  let ping =
    Write
      (fun bw ->
        write_ping_frame bw
          (Cstruct.of_string "12345678")
          (create_frame_info 0l);
        Buf_write.flush bw)

  let goaway =
    Write
      (fun bw ->
        write_goaway_frame bw 0l NoError;
        Buf_write.flush bw)
end

module Sets = struct
  let preface : step list =
    [
      Expect.magic;
      Expect.settings;
      Write.settings;
      Write.settings_ack;
      Expect.settings_ack;
    ]
end
