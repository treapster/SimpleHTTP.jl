
module Common

import JSON
import MacroTools
using Match
const Maybe{T} = Union{T, Nothing}
import HTTP
import OrderedCollections: OrderedDict
import Sockets: IPAddr

const default_response_headers::Vector{Pair{String, String}} =
    Pair{String, String}["Content-Type"=>"application/json;charset=UTF-8"]

const AbstractExpr = Union{Symbol, Expr, QuoteNode, String}
@enum ArgLoc QUERY URL JSONFIELD JSONBODY ALLHEADERS HEADER

@kwdef struct ParamData
    type::AbstractExpr
    default::Maybe{AbstractExpr}
    loc::ArgLoc
    headerKey::String
end

function ParamData(type, default, loc)
    return ParamData(type, default, loc, "")
end

write_json(x) = JSON.json(x; allownan = true)
read_json(x, T) = JSON.parse(x, T; allownan = true)
deserialize(x, T) = read_json(x, T)
serialize(x) = write_json(x)

function make_response(code, content)
    if code == 204
        body = UInt8[]
    else
        body = content
    end
    return HTTP.Response(code, default_response_headers, body)
end

function report_error(e)
    buff = IOBuffer()
    print(buff, string(e))
    Base.show_backtrace(buff, catch_backtrace())
    @error String(take!(buff))
end

function error_string(e::T) where {T <: Exception}
    flds = fieldnames(T)
    if length(flds) == 1 &&
        only(fieldtypes(T))  <: AbstractString
        return getproperty(e, only(flds))
    end
    return string(e)
end

struct ErrorResponse
    error::String
end

function ErrorResponse(e::Exception)
    return ErrorResponse(error_string(e))
end

function get_param_data(argname, type_expr, path, default)
    if MacroTools.@capture(type_expr, Json{argtype_})
        isnothing(default) || error("Full body can't have default value")
        return ParamData(argtype, default, JSONBODY)
    end
    MacroTools.@capture(type_expr, JsonField{argtype_}) &&
        return ParamData(argtype, default, JSONFIELD)

    MacroTools.@capture(type_expr, Json) &&
        error("Json type not provided for \"$argname\"")
    MacroTools.@capture(type_expr, JsonField) &&
        error("Field type not provided for \"$argname\"")

    MacroTools.@capture(type_expr, Headers) &&
        return ParamData(:(Dict{String, String}), default, ALLHEADERS)

    if MacroTools.@capture(type_expr, Headers[key_])
        key isa String || error("expected string for header key in $argname")
        return ParamData(:String, default, HEADER, lowercase(key))
    end

    if contains(path, '{' * string(argname) * '}')
        isnothing(default) || error("Url params cannot have default value")
        return ParamData(type_expr, default, URL)
    end

    return ParamData(type_expr, default, QUERY)
end

function parse_params(args, path, route_name)
    params = OrderedDict{Symbol, ParamData}()

    for arg_expr in args
        argdefault = nothing
        MacroTools.@capture(arg_expr, argname_Symbol::argtype_ = argdefault_) ||
            MacroTools.@capture(arg_expr, argname_Symbol::argtype_) ||
            error("route $route_name: invalid argument $arg_expr")

        haskey(params, argname) &&
            error("route $route_name: duplicate argument $argname")
        params[argname] = get_param_data(argname, argtype, path, argdefault)
    end
    return params
end

end
