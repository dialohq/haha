module WindowSize = struct
  type t = int32

  let default_initial_window_size = 65535l
  let max_window_size = Int32.max_int
  let initial_increment = Int32.sub max_window_size default_initial_window_size
  let is_window_overflow n = Util.test_bit_int32 n 31
end

type t = {
  out_flow : WindowSize.t;
  sent : WindowSize.t;
  received : WindowSize.t;
}

let initial = { out_flow = 0l; sent = 0l; received = 0l }

let receive_data ~(send_update : int32 -> unit) t n =
  let open Int32 in
  let in_window = sub WindowSize.max_window_size t.received in

  let new_in_window = sub in_window n in

  if compare (div WindowSize.max_window_size 2l) new_in_window > 0 then (
    let increment = sub WindowSize.max_window_size new_in_window in
    send_update increment;
    { t with received = 0l })
  else { t with received = add t.received n }

let is_overflow t ~initial_window_size =
  Int32.(compare t.sent (add t.out_flow initial_window_size)) > 0

let incr_out_flow t n = { t with out_flow = Int32.add t.out_flow n }

let incr_sent t n ~initial_window_size =
  let new_flow = { t with sent = Int32.(add t.sent n) } in

  if is_overflow ~initial_window_size new_flow then Error () else Ok new_flow

let pp_hum fmt t =
  let open Format in
  fprintf fmt "@[<v 2>{";
  fprintf fmt "out_flow = %li" t.out_flow;
  fprintf fmt "@ sent = %li" t.sent;
  fprintf fmt "@]}"
