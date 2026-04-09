

module Server

using ..Common: make_response, report_error, ParamData, read_json,
    write_json, ErrorResponse, MetaType, parse_params, strip_meta

import OrderedCollections: OrderedDict
import MacroTools
import HTTP
import Sockets: IPAddr, @ip_str
using Try
using Try: iserr

abstract type Extractor{T} <: MetaType end
struct JsonField{T} <: Extractor{T} end
struct Url{T} <: Extractor{T} end
struct Query{T} <: Extractor{T} end
struct JsonBody{T} <: Extractor{T} end
struct Headers{T} <: Extractor{T} end
struct Header{T, HdrName} <: Extractor{T} end

struct Handler{F, Meta, RespSerializer}
    impl::F
    args_meta::Meta # Meta is NamedTuple
    method::String
    path::String
    ser::RespSerializer
    errors::Vector{Pair{Type, Int}}
end

abstract type ResponseSerializer{T} end
struct JsonResponseSerializer{T} <: ResponseSerializer{T} end

serialize_response(::JsonResponseSerializer, x) = write_json(x)

@kwdef struct Router
    router::HTTP.Router= HTTP.Router()
    path::String
    routes::Vector{Handler} = Handler[]
    verbosity_500::Int = 0
end

function register!(router::Router, @nospecialize(hdl::Handler); with_internal = true)
    if with_internal
        register_internal!(router, hdl)
    end
    full_path = rstrip(router.path, '/') * '/' * lstrip(hdl.path, '/')
    HTTP.register!(
        router.router,
        hdl.method,
        full_path,
        hdl,
    )
    push!(router.routes, hdl)
end

function register_internal!(router::Router, @nospecialize(hdl::Handler))
    internal_path = "internal/" * lstrip(hdl.path, '/')
    full_path = rstrip(router.path, '/') * '/' * internal_path
    internal_hdl = Handler(
        hdl.impl,
        hdl.args_meta,
        hdl.method,
        internal_path,
        hdl.ser,
        hdl.errors,
    )
    HTTP.register!(
        router.router,
        internal_hdl.method,
        full_path,
        internal_hdl,
    )
    push!(router.routes, internal_hdl)
end

function serve!(router::Router, ip::IPAddr, port::Int; kw...)
    return HTTP.serve!(router, ip, port; kw...)
end

function find_err_code(code_map, e::Exception)
    for (type, code) in code_map
        if e isa type
            return code
        end
    end
    return nothing
end

function error_response(errors_map, e::Exception, verbosity_500::Int)
    code = find_err_code(errors_map, e)
    if isnothing(code)
        if verbosity_500 > 0
            buff = IOBuffer()
            print(buff, string(e))
            if verbosity_500 > 1
                Base.show_backtrace(buff, catch_backtrace())
            end
            err = String(take!(buff))
        else
            err = "Internal server error"
        end
        return make_response(500,
            serialize_response(JsonResponseSerializer(), ErrorResponse(err))
        )
    end
    return make_response(code, serialize_response(JsonResponseSerializer(), e))
end

function error_response(error::String)
    return make_response(
        422,
        write_json(ErrorResponse(error)),
    )
end

function no_param_provided_response(param_name::String, is_header::Bool)
    return make_response(
        422,
        write_json(
            ErrorResponse("Required $(is_header ? "header" : "parameter") \"$param_name\" not provided"),
        ),
    )
end

function normalize_headers(
    hdrs
)
    return ((lowercase(hdr) => value) for (hdr, value) in hdrs)
end

const HandlerParams = Dict{String, Any}
const ExtractResult = Union{Ok{HandlerParams}, Err{String}}

function extract_params(::Type{Url}, req, arg_to_type)::ExtractResult
    isempty(arg_to_type) && return HandlerParams()
    params = HTTP.getparams(req)
    res = HandlerParams()
    isnothing(params) && return Ok(res)
    for (k, v) in params
        name = Symbol(k)
        T = get(arg_to_type, name, nothing)
        isnothing(T) && continue
        try
            res[name] = parse(first(T.parameters), v)
        catch e
            return Err("Error url param $name: $e")
        end
    end
    return Ok(res)
end

function extract_params(::Type{Query}, req, arg_to_type)::ExtractResult
    isempty(arg_to_type) && return HandlerParams()
    params = HTTP.queryparams(req)
    res = HandlerParams()

    for (k, v) in params
        name = Symbol(k)
        T = get(arg_to_type, name, nothing)
        isnothing(T) && continue
        try
            res[name] = parse(first(T.parameters), v)
        catch
            return Err("Error parsing query param $name: $e")
        end
    end
    return Ok(res)
end

function extract_params(::Type{JsonField}, req, arg_to_type)::ExtractResult
    isempty(arg_to_type) && return HandlerParams()
    json = JSON.lazy(req.body)
    res = HandlerParams()
    try
        for (k, v) in json
            name = Symbol(k)
            T = get(arg_to_type, name, nothing)
            isnothing(T) && continue
            res[k] = JSON.parse(v, first(T.parameters); allow_nan = true)
        end
    catch e
        Err("Error parsing json: $e")
    end
    return Ok(res)
end

function extract_params(::Type{Header}, req, arg_to_type)::ExtractResult
    isempty(arg_to_type) && return HandlerParams()
    argname = only(keys(arg_to_type))
    hdr = string(Sym)
    res = HandlerParams()
    try
        for (k, v) in req.headers
            name = Symbol(k)
            T = get(arg_to_type, name, nothing)
            isnothing(T) && continue
            type = first(T.parameters)
            if type isa Type{<:AbstractString}
                res[T.parameters[2]] = string(v)
            end
            res[argname] = parse(T, v)
        end
    catch e
        Err("Error parsing header: $hdr $e")
    end
    return Ok(res)
end

function extract_params(::Type{JsonBody}, req, arg_to_type)::ExtractResult
    isempty(arg_to_type) && return HandlerParams()
    argname = only(keys(arg_to_type))
    T = only(values(arg_to_type)).parameters |> first
    try
        return HandlerParams(argname => JSON.parse(v, T; allow_nan = true))
    catch e
        Err("Error parsing header: $hdr $e")
    end
    return Ok(res)
end

function _outer_type(::Type{T}) where T
    return T.name.wrapper
end

function _get_grouped_extractors(params::NamedTuple)
    type_to_extractors = Dict{Type, Dict{Symbol, Type}}()
    for (name, type) in pairs(params)

        outer = _outer_type(type)
        dict = get!(type_to_extractors, outer, Dict{Symbol, Type}())
        dict[name] = type

    end
    return type_to_extractors
end

function _extract_params(req, params)::ExtractResult
    grouped_extractors = _get_grouped_extractors(params)
    res = HandlerParams()
    for (type, extractors) in grouped_extractors
        params = @? extract_params(type, req, extractors)
        merge!(res, params)
    end
    return Ok(res)
end

function _get_bodytype(mod, rettype)
    type = Core.eval(mod, rettype)
    if type isa Type{ResponseSerializer}
        return type
    else
        return JsonResponseSerializer{type}
    end
end

function create_route(mod, path, func, method, err_map)
    #! format: off
    MacroTools.@capture(func, function route_name_(args__)::rettype_expr_
        functionbody_
    end) || error("Invalid route signature. Maybe you forgot return type?")
    #! format: on
    func_args = Any[]
    params = parse_params(mod, args, path, route_name)

    body_ser = _get_bodytype(mod, rettype_expr)
    rettype = strip_meta(body_ser)
    argdefs = []

    for (argname, param) in params
        if !isnothing(param.default)
            push!(argdefs, :(
                $argname = $get(args, $(QuoteNode(argname))) do
                    $(param.default)
                end)
            )
        else
            push!(argdefs, quote
                $argname = $get(args, $(QuoteNode(argname)), missing)
                if $ismissing($argname)
                    return $no_param_provided_response($(string(argname)), false)
                end
            end)
        end
    end

    stripped_args = Iterators.map(params) do (name, param)
        if isnothing(param.default)
            :($name::$(strip_meta(param.type)))
        else
            Expr(:kw, :($name::$(strip_meta(param.type))), param.default)
        end
    end

    func_args = Iterators.map(params) do (argname, par)
        return :($(argname)::$(strip_meta(par.type)))
    end

    argnames = collect(keys(params))
    #! format: off
    handler_impl = :(function ($(func_args...),)
        $functionbody
    end)

    handler_func = :(function (__handler_self::$typeof($route_name))($(stripped_args...))::$rettype
        return __handler_self.impl($(keys(params)...))
    end)

    http_handler = :(
        function (__handler_self::$typeof($route_name))(req::$(HTTP.Request))
            maybe_args = $_extract_params(req, __handler_self.args_meta)
            if $iserr(maybe_args)
                return $error_response(maybe_args.value)
            end
            args = maybe_args.value
            $(argdefs...)
            res = try
                __handler_self($(argnames...))
            catch e
                $report_error(e)
                return $error_response(__handler_self.errors, e, 1)
            end
            code = isnothing(res) ? 204 : 200
            return $make_response(code, $serialize_response(__handler_self.ser, res))
        end
    )
    #! format: on
    esc(
        quote
            const $route_name = $Handler(
                $handler_impl,
                $(Expr(:tuple, (:($name = $(param.type)) for (name, param) in params)...)),
                $method,
                $path,
                $body_ser,
                $err_map
            )
            $handler_func,
            $http_handler
        end,
    )

end

@doc raw"""
```julia
API.@get(
    cfg,
    "/local/hello/{name}",
    function hello(name::String)::String
        return "Hello, $name"
    end
)
```
"""
macro get(path, handler, err_map)
    return create_route(__module__, path, handler, "GET", err_map)
end

macro post(path, handler, err_map)
    return create_route(__module__, path, handler, "POST", err_map)
end

macro delete(path, handler, err_map)
    return create_route(__module__, path, handler, "POST", err_map)
end

macro put(path, handler, err_map)
    return create_route(__module__, path, handler, "PUT", err_map)
end

end
