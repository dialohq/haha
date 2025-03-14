module WindowSize = struct
  type t = int32

  (* From RFC7540§6.9.2:
   *   When an HTTP/2 connection is first established, new streams are created
   *   with an initial flow-control window size of 65,535 octets. *)
  let default_initial_window_size = 65535l

  (* By default we set a big window_size increment so we don't have to send
     many WINDOW_UPDATE packets through the whole lifetime of the connection.
     TODO: this should be configurable in the API
     *)
  let initial_increment = 1_073_741_824l

  (* From RFC7540§6.9:
   *   The legal range for the increment to the flow-control window is 1 to
   *   2^31-1 (2,147,483,647) octets. *)
  let max_window_size = Int32.max_int

  (* Ideally `n` here would be an unsigned 32-bit integer, but OCaml doesn't
   * support them. We avoid introducing a new dependency on an unsigned integer
   * library by letting it overflow at parse time and checking if bit 31 is set
   * here, since * `Window.max_window_size` is never allowed to be above
   * 2^31-1 (see `max_window_size` above).
   * See http://caml.inria.fr/pub/ml-archives/caml-list/2004/07/f1c483068cc62075c916f7ad7d640ce0.fr.html
   * for more info. *)
  let is_window_overflow n = Util.test_bit_int32 n 31
end

type t = { out_flow : WindowSize.t; sent : WindowSize.t }

let is_overflow t ~initial_window_size =
  Int32.(compare t.sent (add t.out_flow initial_window_size)) > 0

let incr_out_flow t n = { t with out_flow = Int32.(add t.out_flow n) }

let incr_sent t n ~initial_window_size =
  let new_flow = { t with sent = Int32.(add t.sent n) } in

  if is_overflow ~initial_window_size new_flow then Error () else Ok new_flow
