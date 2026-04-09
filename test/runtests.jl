
using SimpleHTTP
using Test


include("server.jl")
include("client.jl")

import UUIDs: uuid4, UUID
import .ServerTest: UserNotFoundError
import .ClientTest as App
server = ServerTest.start(ServerTest.cfg)

struct UnexpectedSuccess <: Exception
    msg::String
end

macro exception(expr)
    return esc(:(
        try
            $expr
            throw(UnexpectedSuccess("Exception expected!"))
        catch e
            e isa UnexpectedSuccess && rethrow()
            e
        end
    ))
end

@testset "basic tests" begin
    invalid_id = UUID(0)
    server_ex = @exception ServerTest.get_user(invalid_id)
    client_ex = @exception App.get_user(invalid_id)
    @test server_ex == client_ex
    @test server_ex.msg == "User id $invalid_id not found"
    id = App.create_user("Dave", 40)
    user = App.get_user(id)
    @test user.name == "Dave"
    @test user.age == 40
    @test App.get_all_users() == Dict(id => user)
    @test App.set_age(id, 20) === nothing
    @test App.get_user(id).age == 20
    @test App.delete_user(id) === nothing
end

@testset "header arguments" begin
    @test App.echo_lang("de") == "de"
    @test App.server_default_lang_en() == "en"
    @test App.client_default_lang_ru() == "ru"
    @test App.client_default_lang_ru("de") == "de"

    headers = Dict("hdr1" => "val1", "BIG-HDR-2" => "val2")
    res = App.echo_headers(headers)
    @test all(res[lowercase(k)] == headers[k] for k in keys(headers))

    default_headers = Dict{String, String}(
        "accept-language" => "ru",
        "auth" => "secret_token"
    )

    res = App.echo_headers_with_default()
    @test all(res[k] == default_headers[k] for k in keys(default_headers))

    res = App.echo_headers_with_default(Dict{String, String}())
    @test all(!haskey(res, k) for k in keys(default_headers))
end
