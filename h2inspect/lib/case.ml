type stream = GET of string | POST of (string * int)

type t = {
  port : int;
  settings : H2kit.Settings.setting list;
  streams : stream list;
}

let yojson_of_stream_list : stream list -> Yojson.Safe.t =
 fun l ->
  `List
    (List.map
       (function
         | POST (path, data) ->
             `Assoc
               [
                 ("type", `String "POST");
                 ("path", `String path);
                 ("data", `Int data);
               ]
         | GET path ->
             `Assoc [ ("type", `String "GET"); ("path", `String path) ])
       l)

let yojson_member_of_setting : H2kit.Settings.setting -> string * Yojson.Safe.t
    = function
  | HeaderTableSize i -> ("HEADER_TABLE_SIZE", `Int i)
  | EnablePush i -> ("ENABLE_PUSH", `Int i)
  | MaxConcurrentStreams li -> ("MAX_CONCURRENT_STREAM", `Int (Int32.to_int li))
  | InitialWindowSize li -> ("INITIAL_WINDOW_SIZE", `Int (Int32.to_int li))
  | MaxFrameSize i -> ("MAX_FRAME_SIZE", `Int i)
  | MaxHeaderListSize i -> ("MAX_HEADER_LIST_SIZE", `Int i)

let yojson_of_cases : t list -> Yojson.Safe.t =
 fun l ->
  `List
    (List.map
       (fun { port; streams; settings } ->
         `Assoc
           [
             ("port", `Int port);
             ("settings", `Assoc (List.map yojson_member_of_setting settings));
             ("streams", yojson_of_stream_list streams);
           ])
       l)
