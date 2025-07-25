open H2kit

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

let make_msg : string list -> Event.t option -> string =
  let open Format in
  fun expected ->
    let expected = String.concat " OR " expected in
    function
    | None -> asprintf "Expected %s" expected
    | Some (Frame f) ->
        asprintf "Expected %s but got a frame:@.@.  %a" expected
          Frame.pp_hum_exact f
    | Some Malformed ->
        asprintf "Expected %s but got a malformed frame" expected
    | Some (ValidationFailed err) ->
        asprintf "Expected %s but validation of the frame faild with error %a"
          expected Error.pp_hum err
    | Some Magic ->
        asprintf "Expected %s but got a client preface magic string" expected
    | Some EOF -> asprintf "Expected %s but got EOF" expected
    | Some Timeout -> asprintf "Timeout, expected %s" expected
