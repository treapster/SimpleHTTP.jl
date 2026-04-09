
module ServerTest

using SimpleHTTP.Server: Server, Router, JsonField as Json, Header, Headers

struct UserNotFoundError <: Exception
    msg::String
end

using Sockets: @ip_str
using UUIDs: uuid4, UUID
const SERVER_IP = ip"0.0.0.0"
const SERVER_PORT = 8080

const cfg = Router(path = "api/v1/test")

errors_map = Pair{Type, Int}[
    UserNotFoundError => 404,
]

mutable struct User
    id::UUID
    age::Int
    name::String
end

function fields_equal(l, r, fields)
    return all((splat(==).((getproperty.((l, r), prop) for prop in fields))))
end

Base.:(==)(l::User, r::User) = fields_equal(l, r, fieldnames(User))

struct CreateUserRequest
    name::String
    age::Int
end

const users = Dict{UUID, User}()

Server.@post(
    "/users/create",
    function create_user(data::Json{CreateUserRequest})::UUID
        id = uuid4()
        users[id] = User(
            id,
            data.age,
            data.name,
        )
        return id
    end,
    errors_map
)

Server.@delete(
    "/users/delete/{id}",
    function delete_user(id::UUID)::Nothing
        delete!(users, [id])
        return nothing
    end,
    errors_map
)

Server.@post(
    "/users/set_age/{id}",
    function set_age(id::UUID, age::Int)::Nothing
        users[id].age = age
        return nothing
    end,
    errors_map
)

Server.@get(
    "/users/get/{id}",
    function get_user(id::UUID)::User
        user = get(users, id, nothing)
        isnothing(user) && throw(UserNotFoundError("User id $id not found"))
        @show user
        return user
    end,
    errors_map
)

Server.@get(
    "/users/get",
    function get_all_users()::Dict{UUID, User}
        return users
    end,
    errors_map
)

macro sym_str(str)
    return QuoteNode(Symbol(str))
end


Server.@get(
    "/users/echo_lang",
    function echo_lang(lang::Header{String, sym"Accept-Language"} = "en")::String
        return lang
    end,
    errors_map
)

Server.@get(
    "/users/echo_headers",
    function echo_headers(hdrs::Headers{Dict{String, Any}})::Dict{String, String}
        return hdrs
    end,
    errors_map,
)


function start()
    for name in names(@__MODULE__; all = true)
        hdl = getproperty(@__MODULE__, name)
        if hdl isa Server.Handler
            Server.register!(cfg, hdl)
        end
    end
    return Server.serve!(router, SERVER_IP, SERVER_PORT)
end

end