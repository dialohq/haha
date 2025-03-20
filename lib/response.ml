type body_fragment = [ `Data of Cstruct.t | `EOF | `Yield ]
type body_writer = int32 -> unit -> body_fragment
type response_type = Unary | Streaming of body_writer

type t = {
  status : Status.t option;
  headers : Headers.t list;
  end_stream : bool;
  response_type : response_type;
}

let create_final (status : Status.final) headers =
  {
    status = Some (status :> Status.t);
    headers;
    end_stream = true;
    response_type = Unary;
  }

let create_final_with_streaming ~body_writer (status : Status.final) headers =
  {
    status = Some (status :> Status.t);
    headers;
    end_stream = false;
    response_type = Streaming body_writer;
  }

let create_interim (status : Status.informational) headers =
  {
    status = Some (status :> Status.t);
    headers;
    end_stream = false;
    response_type = Unary;
  }

let create_trailers trailers =
  {
    status = None;
    headers = trailers;
    end_stream = true;
    response_type = Unary;
  }
