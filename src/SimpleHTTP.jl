module SimpleHTTP

import HTTP
import Sockets: IPAddr, @ip_str

include("Common.jl")
include("Server.jl")
include("Client.jl")

export HTTP, @ip_str, IPAddr
import .Server: Server, Router
export Server, Router

import .Client: Client, ClientConfig
export Client, ClientConfig
end # module SimpleHTTP
