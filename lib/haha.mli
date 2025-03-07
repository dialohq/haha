val listen :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  Bigstringaf.t Eio.Stream.t ->
  [> [> `Generic ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  unit
