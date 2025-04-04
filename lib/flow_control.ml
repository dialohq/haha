module WindowSize = struct
  type t = int32

  let default_initial_window_size = 65535l

  (* TODO: this should be configurable in the API *)
  let initial_increment = 1_073_741_824l
  let max_window_size = Int32.max_int
  let is_window_overflow n = Util.test_bit_int32 n 31
end

type t = { out_flow : WindowSize.t; sent : WindowSize.t }

let initial = { out_flow = 0l; sent = 0l }

let is_overflow t ~initial_window_size =
  Int32.(compare t.sent (add t.out_flow initial_window_size)) > 0

let incr_out_flow t n = { t with out_flow = Int32.(add t.out_flow n) }

let incr_sent t n ~initial_window_size =
  let new_flow = { t with sent = Int32.(add t.sent n) } in
  (* Printf.printf *)
  (*   "Previous sent: %li | New sent: %li | Initial window: %li | Out flow: %li\n\ *)
  (*    %!" *)
  (*   t.sent new_flow.sent initial_window_size t.out_flow; *)

  if is_overflow ~initial_window_size new_flow then Error () else Ok new_flow

let max t1 t2 =
  {
    out_flow = Int32.max t1.out_flow t2.out_flow;
    sent = Int32.max t1.sent t2.sent;
  }

let pp_hum fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "out_flow = %li" t.out_flow;
  fprintf fmt "@ sent = %li" t.sent;
  fprintf fmt "@]}"
