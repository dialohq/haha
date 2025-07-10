open Cmdliner
open H2inspect
open Eio
open Cohttp_eio

let client first_port helper_port =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let cases = run_server_tests ~first_port ~sw env#clock env#net in
  Printf.printf "Running tests servers on ports %i-%i\n%!" first_port
    (first_port + List.length cases);

  let cases_json = Case.yojson_of_cases cases in
  let stop_helper_p, stop_helper_r = Promise.create () in

  let server =
    Server.make
      ~callback:(fun _ _ _body ->
        Promise.resolve stop_helper_r ();
        Server.respond_string ~status:`OK
          ~body:(Yojson.Safe.to_string cases_json)
          ())
      ()
  in

  let helper_socket =
    Net.listen ~sw ~backlog:10 ~reuse_addr:true env#net
      (`Tcp (Net.Ipaddr.V4.any, helper_port))
  in

  Printf.printf "Running helper server on port %i\n\n%!" helper_port;
  Server.run ~stop:stop_helper_p ~on_error:ignore helper_socket server

let first_port =
  let env =
    let doc =
      "Overrides the default first port to begin the tests servers with."
    in
    Cmd.Env.info "FIRST_PORT" ~doc
  in
  let doc = "Start tests servers beggining with the port $(docv)." in
  Arg.(value & opt int 8050 & info [ "p"; "first-port" ] ~docv:"PORT" ~doc ~env)

let helper_port =
  let env =
    let doc = "Overrides the default port of helper server." in
    Cmd.Env.info "HELPER_PORT" ~doc
  in
  let doc = "Start the helper server for fetching script on port $(docv)." in
  Arg.(
    value & opt int 3000 & info [ "H"; "helper-port" ] ~docv:"H_PORT" ~doc ~env)

let chorus_t = Term.(const client $ first_port $ helper_port)

let client_cmd =
  let doc =
    "start test servers and script server for client conformance testing."
  in
  let man =
    [ `S Manpage.s_bugs; `P "Report bugs at <github.com/dialohq/haha/issues>." ]
  in
  let info = Cmd.info "client" ~version:"0.0.1" ~doc ~man in
  Cmd.v info chorus_t

let main_cmd =
  Cmd.group (Cmd.info "h2inspect" ~version:" %VERSION%%") [ client_cmd ]

let main () = exit (Cmd.eval main_cmd)
let () = main ()
