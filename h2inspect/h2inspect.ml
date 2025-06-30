open Eio
open Steps
module I = Ignore
module E = Expect
module W = Write

let run_server_tests ~sw net =
  Fiber.fork ~sw @@ fun () ->
  Switch.run @@ fun sw ->
  let connection_level_group : Runner.test_group =
    {
      label = "Connection-level";
      tests =
        [
          {
            label = "Initialization, standard preface exchange";
            steps =
              [
                E.magic;
                E.settings;
                W.settings;
                W.settings_ack;
                E.settings_ack;
                W.goaway;
              ];
            description =
              Some
                {|[Section 3.4. of RFC9113] "In HTTP/2, each endpoint is required to send a connection preface as a final confirmation of the protocol in use and to establish th initial settings for the HTTP/2 connection."|};
          };
          {
            label = "Server sends invalid connection preface";
            steps = [ E.magic; E.settings; W.ping; E.goaway ];
            description =
              Some
                {|[Section 3.4 of RFC9113] "The server connection preface consists of a potentially empty SETTINGS frame (Section 6.5) that MUST be @{<ul>the first frame the server sends@} in the HTTP/2 connection. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
          };
          {
            label =
              "Server acknowledges client's SETTINGS before sending its preface";
            steps = [ E.magic; E.settings; W.settings_ack; E.goaway ];
            description =
              Some
                {|[Section 3.4. of RFC9113] "The SETTINGS frames received from a peer as part of the connection preface MUST be acknowledged (see Section 6.5.3) @{<ul>after@} sending the connection preface. [...] Clients and servers MUST treat an invalid connection preface as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."|};
          };
          {
            label = "Ping-pong";
            steps =
              [
                I.window_update;
                E.magic;
                E.settings;
                W.settings;
                E.settings_ack;
                W.settings_ack;
                W.ping;
                E.ping;
                W.goaway;
              ];
            description = None;
          };
        ];
    }
  in

  let groups : Runner.test_group list = [ connection_level_group ] in

  Runner.run_groups ~sw ~net groups
