
module ServerTest

using SimpleHTTP

struct UserNotFoundError <: Exception
    msg::String
end

using UUIDs: uuid4, UUID
const cfg = ServerConfig(;
    ip = ip"0.0.0.0",
    port = 8080,
    path = "/api/v1/test",
    verbosity_500 = 2,
)

const error_codes = Pair{DataType, Int}[UserNotFoundError=>404,]

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
    cfg,
    "/users/create",
    function create_user(data::Json{CreateUserRequest})::UUID
        id = uuid4()
        users[id] = User(id, data.age, data.name)
        return id
    end,
    error_codes
)

Server.@delete(
    cfg,
    "/users/delete/{id}",
    function delete_user(id::UUID)::Nothing
        delete!(users, id)
        return nothing
    end,
    error_codes
)

Server.@post(
    cfg,
    "/users/set_age/{id}",
    function set_age(id::UUID, age::Int)::Nothing
        users[id].age = age
        return nothing
    end,
    error_codes
)

Server.@get(
    cfg,
    "/users/get/{id}",
    function get_user(id::UUID)::User
        user = get(users, id, nothing)
        isnothing(user) && throw(UserNotFoundError("User id $id not found"))
        return users[id]
    end,
    error_codes
)

Server.@get(
    cfg,
    "/users/get",
    function get_all_users()::Dict{UUID, User}
        return users
    end,
    error_codes
)

Server.@get(
    cfg,
    "/users/echo_lang",
    function echo_lang(lang::Headers["Accept-Language"] = "en")::String
        return lang
    end,
    error_codes
)

Server.@get(
    cfg,
    "/users/echo_headers",
    function echo_headers(hdrs::Headers)::Dict{String, String}
        return hdrs
    end,
    error_codes
)

Server.@get(
    cfg,
    "/users/names",
    function get_user_names()::Vector{String}
        return sort([u.name for u in values(users)])
    end,
    error_codes
)

Server.@get(
    cfg,
    "/users/ages",
    function get_user_ages()::Vector{Int}
        return sort([u.age for u in values(users)])
    end,
    error_codes
)

end
