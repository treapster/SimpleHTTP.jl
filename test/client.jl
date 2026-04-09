
module ClientTest

using ..ServerTest: User, UserNotFoundError
using SimpleHTTP
using UUIDs: uuid4, UUID

const cfg = ClientConfig(; url = "http://0.0.0.0:8080/api/v1/test")

const exceptions = Dict{Int, Type{<:Exception}}(404 => UserNotFoundError)

Client.@post(
    cfg,
    "/users/create",
    create_user(name::JsonField{String}, age::JsonField{Int})::UUID,
    exceptions
)

Client.@delete(
    cfg,
    "/users/delete/{id}",
    delete_user(id::UUID)::Nothing,
    exceptions
)

Client.@post(
    cfg,
    "/users/set_age/{id}",
    set_age(id::UUID, age::Int)::Nothing,
    exceptions
)

Client.@get(cfg, "/users/get/{id}", get_user(id::UUID)::User, exceptions)

Client.@get(cfg, "/users/get", get_all_users()::Dict{UUID, User}, exceptions)

Client.@get(
    cfg,
    "/users/echo_lang",
    echo_lang(lang::Headers["Accept-Language"])::String,
    exceptions
)

Client.@get(
    cfg,
    "/users/echo_lang",
    server_default_lang_en()::String,
    exceptions
)

Client.@get(
    cfg,
    "/users/echo_lang",
    client_default_lang_ru(; lang::Headers["Accept-Language"] = "ru")::String,
    exceptions
)

Client.@get(
    cfg,
    "/users/echo_headers",
    echo_headers(hdrs::Headers)::Dict{String, String},
    exceptions
)

Client.@get(
    cfg,
    "/users/echo_headers",
    echo_headers_with_default(;
        hdrs::Headers = Dict{String, String}(
            "accept-language" => "ru",
            "auth" => "secret_token",
        ),
    )::Dict{String, String},
    exceptions
)

Client.@get(cfg, "/users/names", get_user_names()::Vector{String}, exceptions)

Client.@get(cfg, "/users/ages", get_user_ages()::Vector{Int}, exceptions)

end
