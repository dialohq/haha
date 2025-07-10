open H2kit

type t =
  | Frame of Frame.t
  | Malformed
  | ValidationFailed of Error.t
  | Magic
  | EOF
  | Timeout

let make_msg : string -> t -> string =
  let open Format in
  fun expected -> function
    | Frame f ->
        asprintf "Expected %s but got a frame %a" expected Frame.pp_hum f
    | Malformed -> asprintf "Expected %s but got a malformed frame" expected
    | ValidationFailed err ->
        asprintf "Expected %s but validation of the frame faild with error %a"
          expected Error.pp_hum err
    | Magic ->
        asprintf "Expected %s but got a client preface magic string" expected
    | EOF -> asprintf "Expected %s but got EOF" expected
    | Timeout -> asprintf "Timeout, expected %s" expected
