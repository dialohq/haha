type t = int32

let ( === ) = Int32.equal
let connection = Int32.zero
let[@inline] is_connection id = Int32.equal id connection
let[@inline] is_client = function 0l -> false | n -> Int32.rem n 2l <> 0l
let[@inline] is_server = function 0l -> false | n -> Int32.rem n 2l === 0l
