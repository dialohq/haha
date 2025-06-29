open H2kit

type expect_action = Element.t -> (unit, string) result
type write_action = Buf_write.t -> unit
type action = Expect of expect_action | Write of write_action
type step = unit -> action

module Expect = struct
  let magic =
   fun () ->
    Expect
      (function Magic -> Ok () | _ -> Error "Expected preface magic string")

  let settings =
   fun () ->
    Expect
      (function
      | Frame { frame_payload = Settings _; frame_header = { flags; _ } } ->
          if Flags.test_empty flags then Ok ()
          else Error "Expected SETTINGS frame without any flags set"
      | _ -> Error "Expected SETTINGS frame")

  let settings_ack =
   fun () ->
    Expect
      (function
      | Frame { frame_payload = Settings _; frame_header = { flags; _ } } ->
          if Flags.test_ack flags then Ok ()
          else Error "Expected SETTINGS frame with ACK flag set"
      | _ -> Error "Expected SETTINGS frame with ACK flag set")

  let ping =
   fun () ->
    Expect
      (function
      | Frame { frame_payload = Ping cs; _ } ->
          if Cstruct.to_string cs = "12345678" then Ok ()
          else Error "Expected PING frame with payload \"12345678\""
      | _ -> Error "Expected PING frame")

  let window_update =
   fun () ->
    Expect
      (function
      | Frame { frame_payload = WindowUpdate _; _ } -> Ok ()
      | _ -> Error "Expected WINDOW_UPDATE frame")
end

module Write = struct
  open Serializers.Make (Buf_write)

  let setting =
   fun () ->
    Write
      (fun bw ->
        write_settings_frame bw [] (create_frame_info 0l);
        Buf_write.flush bw)

  let settings_ack =
   fun () ->
    Write
      (fun bw ->
        write_settings_frame bw []
          (create_frame_info ~flags:H2kit.Flags.(default_flags |> set_ack) 0l);
        Buf_write.flush bw)

  let ping =
   fun () ->
    Write
      (fun bw ->
        write_ping_frame bw
          (Cstruct.of_string "12345678")
          (create_frame_info 0l);
        Buf_write.flush bw)

  let goaway =
   fun () ->
    Write
      (fun bw ->
        write_goaway_frame bw 0l NoError;
        Buf_write.flush bw)
end
