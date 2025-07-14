open H2kit

type t = Event.t -> bool

let nothing = fun _ -> false
let add : t -> t -> t = fun f1 f2 el -> if f1 el then true else f2 el
let ( + ) = add

let frame_type : Frame.FrameType.t -> t =
 fun frame_type' -> function
  | Frame { frame_header = { frame_type; _ }; _ } when frame_type = frame_type'
    ->
      true
  | _ -> false

let stream_frames : t =
  frame_type Headers + frame_type Data + frame_type RSTStream
  + frame_type PushPromise + frame_type Continuation
