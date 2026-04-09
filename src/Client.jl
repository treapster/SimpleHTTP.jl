
module Client

using ..Common: make_response, report_error, ParamData, read_json,
    parse_params, write_json, ErrorResponse, deserialize, MetaType, strip_meta

import OrderedCollections: OrderedDict
import MacroTools
import HTTP

abstract type RequestSerializer{T} <: MetaType end
abstract type RequestBodySerializer{T} <: RequestSerializer{T} end
abstract type RequestHeadersSerializer{T} <: RequestSerializer{T} end
abstract type RequestUrlSerializer{T} <: RequestSerializer{T} end
abstract type RequestQuerySerializer{T} <: RequestSerializer{T} end

struct JsonField{T} <: RequestBodySerializer{T} end
struct Json{T} <: RequestBodySerializer{T} end
struct Url{T} <: RequestUrlSerializer{T} end
struct Query{T} <: RequestQuerySerializer{T} end
struct Header{T, Sym} <: RequestHeadersSerializer{Dict{String, String}} end
struct Headers{T} <: RequestHeadersSerializer{T} end

function serialize(::JsonField, args)
    return write_json(args)
end

function serialize(::Json, args)
    arg = only(values(args))
    return write_json(arg)
end

function serialize(::Url, args)
    return Dict{Symbol, String}(
        name => string(val) for (name, val) in args
    )
end

function serialize(::Query, args)
    return Pair{String, String}[
        string(name) => string(val) for (name, val) in args
    ]
end

function build_url(url_pattern, serialized_args)
    url = url_pattern
    for (name, value) in serialized_args
        url = replace(url, ('{' * string(name) * '}') => value)
    end
    return url
end

struct UnexpectedResponseError <: Exception
    code::Int
    msg::String
end

@kwdef struct ClientConfig
    url::String
    logger::Base.AbstractLogger = Base.global_logger()
end

function construct_body_type(
    fieldinfo::OrderedDict{Symbol, ParamData},
    route_name::Symbol,
)
    fields = []
    for (name, arg) in fieldinfo
        @assert arg.loc == JSONFIELD
        type = arg.type
        symname = Symbol(name)
        push!(fields, :($symname::$type))
    end

    structname = gensym(Symbol("Body_For_" * string(route_name)))
    return structname, :(struct $structname
        $(fields...)
    end)
end

function get_path_parts(path)
    last = length(path)
    new_path = Any[]
    for (i, part) in enumerate(path)
        if i == last
            push!(new_path, part)
            break
        end
        if part isa AbstractString
            push!(new_path, "$part/")
            continue
        end
        if part isa Symbol
            push!(new_path, part)
            push!(new_path, "/")
            continue
        end
        error("Unknown type $(typeof(part))")
    end
    return new_path
end

function get_error(resp)
    try
        read_json(resp.body, ErrorResponse).error
    catch e
        return String(resp.body)
    end
end

function get_exception(resp, err_map)
    if !haskey(err_map, resp.status)
        throw(UnexpectedResponseError(
            resp.status,
            get_error(resp)
        ))
    end
    type = err_map[resp.status]
    return deserialize(resp.body, type)
end

function get_headers_def(params)
    headers = filter(((_, par),) -> par.loc == HEADER, params)
    all_headers = filter(((_, par),) -> par.loc == ALLHEADERS, params)
    if !isempty(headers) && !isempty(all_headers)
        error("Cannot have individual headers and generel Headers in one signature")
    end
    if isempty(headers) && isempty(all_headers)
        return :headers, :(headers = Dict{String, String}())
    end
    if !isempty(all_headers)
        var_name = only(keys(all_headers))
        return :headers, :(headers = $var_name)
    end
    pairs = (:($(par.headerKey) => $var_name) for (var_name, par) in headers)
    return :headers, :(headers = Dict{String, String}(
        $(pairs...)
    ))
end


function _serialize_request(req, params)::ExtractResult
    grouped_extractors = _get_grouped_serializers(params)
    res = HandlerParams()
    for (type, extractors) in grouped_extractors
        params = @? extract_params(type, req, extractors)
        merge!(res, params)
    end
    return Ok(res)
end

function _get_grouped_serializers(params::NamedTuple)
    type_to_extractors = Dict{Type, Dict{Symbol, Type}}()
    for (name, type) in pairs(params)
        outer = _outer_type(type)
        dict = get!(type_to_extractors, outer, Dict{Symbol, Type}())
        dict[name] = type
    end
    return type_to_extractors
end

function construct_expressions(cfg, path, method, sig, err_map)
    MacroTools.@capture(sig, route_name_(args__)::rettype_) ||
        error("Invalid endpoint signature. Maybe you forgot return type?")
    params = parse_params(args, path, route_name)

    stripped_args = Iterators.map(params) do (name, param)
        if isnothing(param.default)
            :($name::$(strip_meta(param.type)))
        else
            Expr(:kw, :($name::$(strip_meta(param.type))), param.default)
        end
    end

    err_map_sym = gensym("errors_for_$route_name")
    handle_errors = quote
        if resp.status >= 300
            throw($get_exception(resp, $err_map_sym))
        end
    end
    if isnothing(create_body_expr)
        res = esc(quote
            const $err_map_sym = $err_map

            function $route_name($(stripped_args...))::$rettype
                return Base.with_logger($cfg.logger) do
                    $headers_def
                    resp = $HTTP.request($method, $cfg.url * $url_patterm;
                        query = [$(query_args...)],
                        headers = $headers_var,
                        status_exception = false)
                    $handle_errors
                    $ret_stmt
                end
            end
        end)
    else
        res = esc(quote
            const $err_map_sym = $err_map
            $body_def

            function $route_name($(func_args...))::$rettype
                return Base.with_logger($cfg.logger) do
                    $headers_def
                    $create_body_expr
                    resp = $HTTP.request($method, $cfg.url * $url_patterm;
                        query = [$(query_args...)],
                        body=req_body,
                        headers = $headers_var,
                        status_exception = false)
                    $handle_errors
                    $ret_stmt
                end
            end
        end)
    end
    return res
end

@doc raw"""
```julia
API.@get(
    cfg,
    "/local/hello/{name}",
    hello(name::String)::String
)
```
"""
macro get(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "GET", sig, err_map)
end

macro post(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "POST", sig, err_map)
end

macro delete(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "DELETE", sig, err_map)
end

macro put(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "PUT", sig, err_map)
end

end
