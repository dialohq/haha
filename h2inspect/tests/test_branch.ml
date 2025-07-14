(* TODO: *)
open H2kit
open H2inspect

let make_fetcher l =
  let dl = Dynarray.of_list (List.rev l) in
  fun () ->
    match Dynarray.pop_last_opt dl with Some ev -> ev | None -> Event.Timeout

let _test_linear () =
  let _await_event =
    make_fetcher
      [
        Magic;
        Frame
          {
            frame_payload = Settings [];
            frame_header =
              {
                frame_type = Settings;
                payload_length = 0;
                stream_id = 0l;
                flags = Flags.default_flags;
              };
          };
        Frame
          {
            frame_payload = Settings [];
            frame_header =
              {
                frame_type = Settings;
                payload_length = 0;
                stream_id = 0l;
                flags = Flags.(default_flags |> set_ack);
              };
          };
        Frame
          {
            frame_payload = GoAway (1l, NoError, Bigstringaf.empty);
            frame_header =
              {
                frame_type = GoAway;
                payload_length = 0;
                stream_id = 0l;
                flags = Flags.default_flags;
              };
          };
        EOF;
      ]
  in

  let expected =
    {|Magic
SETTINGS
+SETTINGS
+SETTINGS_ACK
SETTINGS_ACK
+GOAWAY
GOAWAY
EOF
OK
|}
  in

  let result = expected in

  Alcotest.(check string "Simple Success") expected result

let () =
  let open Alcotest in
  run "H2inspect.Branch" []
