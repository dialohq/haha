type client = private C [@warning "-37"]
type server = private S [@warning "-37"]
type _ t = Client : client t | Server : server t
