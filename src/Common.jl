
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

@kwdef struct ParamData
    type::Type
    default::Maybe{AbstractExpr}
end

write_json(x) = JSON.json(x; allownan = true)
read_json(x, T) = JSON.parse(x, T; allownan = true)
deserialize(x, T) = read_json(x, T)

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

# metatype is either extractor or serializer, it is stripped from generated signature
abstract type MetaType end

function parse_params(mod, args, path, route_name)
    params = OrderedDict{Symbol, ParamData}()

    url_args = Symbol[]
    for arg in split(path, '/')
        m = match(r"\{(\w+)\}", arg)
        isnothing(m) && continue
        argname = only(m.captures)
        push!(url_args, Symbol(argname))
    end

    for arg_expr in args
        argdefault = nothing
        MacroTools.@capture(arg_expr, argname_Symbol::argtype_ = argdefault_) ||
            MacroTools.@capture(arg_expr, argname_Symbol::argtype_) ||
            error("route $route_name: invalid argument $arg_expr")

        haskey(params, argname) &&
            error("route $route_name: duplicate argument $argname")

        T = Core.eval(mod, argtype)
        if T isa Type{<:MetaType}
            params[argname] = ParamData(T, argdefault)
            continue
        end
        extr = if argname ∈ url_args
            Url{T}
        else
            Query{T}
        end
        params[argname] = ParamData(extr, argdefault)
    end

    for arg in url_args
        haskey(params, arg) || error(
            "\"$argname\" provided in path but has no corresponding parameter in signature",
        )
    end
    return params
end


function strip_meta(type::Type)
    if type isa Type{<:MetaType}
        return first(type.parameters)
    end
    return type
end

end
