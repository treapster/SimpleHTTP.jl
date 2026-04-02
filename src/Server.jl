

module Server

using ..Common: make_response, report_error, ParamData, read_json,
    parse_params, write_json, ArgLoc, serialize,
    JSONFIELD, URL, QUERY, JSONBODY, ALLHEADERS, HEADER, ErrorResponse

import OrderedCollections: OrderedDict
import MacroTools
import HTTP
import Sockets: IPAddr, @ip_str

@kwdef struct ServerConfig
    ip::IPAddr
    port::Int
    path::String
    router::HTTP.Router = HTTP.Router()
    verbosity_500::Int
end

get_query_params(req::HTTP.Request) = req.target |> HTTP.URI |> HTTP.queryparams

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
            serialize(ErrorResponse(err))
        )
    end
    return make_response(code, serialize(e))
end

function parsing_error_response(e::Exception, type::Type)
    return make_response(
        422,
        write_json(ErrorResponse("Error parsing type $type: $e")),
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

function construct_body_type(
    fieldinfo::OrderedDict{Symbol, ParamData},
    route_name::Symbol,
)
    fields = []
    for (name, arg) in fieldinfo
        @assert arg.loc == JSONFIELD
        if !isnothing(arg.default)
            type = :(Union{$(arg.type), Nothing})
        else
            type = arg.type
        end
        symname = Symbol(name)
        push!(fields, :($symname::$type))
    end

    structname = gensym(Symbol("Body_For_" * string(route_name)))
    return structname, esc(:(struct $structname
        $(fields...)
    end))
end

function normalize_headers(
    hdrs
)
    return ((lowercase(hdr) => value) for (hdr, value) in hdrs)
end

function construct_handler(
    params,
    body_type,
    rettype,
    route_function::Symbol,
    errors_map,
    cfg_expr,
)
    arg_defs = []
    resp_code = rettype == :Nothing ? 204 : 200
    if !isnothing(body_type)
        parsing = :(parsedbody = try
            $read_json(req.body, $body_type)
        catch e
            $report_error(e)
            return $parsing_error_response(e, $body_type)
        end)
    else
        parsing = :(parsedbody = nothing)
    end

    for (argname, param) in params
        argname_str = string(argname)
        if param.loc == JSONFIELD
            push!(arg_defs, :($argname = if !isnothing(parsedbody.$(argname))
                parsedbody.$(argname)
            else
                $(param.default)
            end))
            continue
        elseif param.loc == JSONBODY
            push!(arg_defs, :($argname = parsedbody))
            continue
        elseif param.loc ∈ [URL, QUERY, HEADER]
            if param.loc == HEADER
                param_source = :req_headers
                is_header = true
                param_key = param.headerKey
            else
                param_source = :queryparams
                is_header = false
                param_key = argname_str
            end
            if isnothing(param.default)
                push!(
                    arg_defs,
                    :(
                        !$haskey($param_source, $param_key) &&
                            return $no_param_provided_response($param_key, $is_header)
                    ),
                )
            end
            if param.type == :String || param.type == :AbstractString
                push!(
                    arg_defs,
                    :($argname = $get($param_source, $param_key, $(param.default))),
                )
                continue
            end
            push!(
                arg_defs,
                :(
                    $argname = if $haskey($param_source, $param_key)
                        try
                            $parse($(param.type), queryparams[$param_key])
                        catch e
                            $report_error(e)
                            return $parsing_error_response(e, $(param.type))
                        end
                    else
                        $(param.default)
                    end
                )
            )
            continue
        elseif param.loc == ALLHEADERS
            if !isnothing(param.default)
                error("Having default for all headers for a server method is currently unsupported")
            end
            push!(
                arg_defs,
                :($argname = req_headers)
            )
            continue
        else
            error("Unknown parameter location $(param.loc)")
        end
    end
    handler_name = gensym(Symbol(string(route_function) * "_handler_"))
    argnames = keys(params)
    return handler_name,
    esc(
        quote
            function $handler_name(req::HTTP.Request)
                queryparams = $merge(
                    $get_query_params(req),
                    something($HTTP.getparams(req), Dict{String, String}()),
                )
                req_headers = Dict{String, String}($normalize_headers(req.headers)...)
                $parsing
                $(arg_defs...)
                res = try
                    $route_function($(argnames...))
                catch e
                    $report_error(e)
                    return $error_response($errors_map, e, ($cfg_expr).verbosity_500)
                end
                return $make_response($resp_code, $serialize(res))
            end
        end,
    )
end

function get_bodytype(params)
    body_params = filter(((_, par),) -> par.loc == JSONFIELD, params)
    body_type_param = filter(((_, par),) -> par.loc == JSONBODY, params)
    if !isempty(body_params) && !isempty(body_type_param)
        error("Cannot have Json and JsonField in one signature")
    elseif !isempty(body_params)
        body_type, body_def = construct_body_type(body_params, route_name)
    elseif !isempty(body_type_param)
        length(body_type_param) == 1 ||
            error("Cannot have multiple bodies in signature")
        body_type = last(only(body_type_param)).type
        body_def = nothing
    else
        body_def = nothing
        body_type = nothing
    end
    return body_def, body_type
end

function create_route_bodies(path, func, cfg, errors)
    #! format: off
    MacroTools.@capture(func, function route_name_(args__)::rettype_
        functionbody_
    end) || error("Invalid route signature. Maybe you forgot return type?")
    #! format: on
    func_args = Any[]
    params = parse_params(args, path, route_name)

    for arg in split(path, '/')
        m = match(r"\{(\w+)\}", arg)
        isnothing(m) && continue
        argname = only(m.captures)
        haskey(params, Symbol(argname)) || error(
            "\"$argname\" provided in path but has no corresponding parameter in signature",
        )
    end

    body_def, body_type = get_bodytype(params)
    errors_var = gensym("errors_for_$route_name")
    errors_def = esc(:(const $errors_var = $errors))
    func_args = Iterators.map(params) do (argname, par)
        return :($(argname)::$(par.type))
    end |> collect
    #! format: off
    handler_func = esc(:(function $route_name($(func_args...))
        $functionbody
    end))
    #! format: on
    handler_name, handler =
        construct_handler(params, body_type, rettype, route_name, errors_var, cfg)
    return errors_def, handler_name, body_def, handler_func, handler
end

function create_route(cfg, path::String, method::String, handler::Expr, errors)
    errors_def, handler_name, body_def, handler_func, handler =
        create_route_bodies(path, handler, cfg, errors)
    return quote
        $errors_def
        $body_def
        $handler_func
        $handler
        $HTTP.register!(
            $(esc(cfg)).router,
            $method,
            $(esc(cfg)).path * $path,
            $(esc(handler_name)),
        )
    end
end

function serve(cfg::ServerConfig)
    HTTP.serve(cfg.router, cfg.port)
end


function serve!(cfg::ServerConfig)
    HTTP.serve!(cfg.router, cfg.port)
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
macro get(cfg, path, handler, errors)
    return create_route(cfg, path, "GET", handler, errors)
end

macro post(cfg, path, handler, errors)
    return create_route(cfg, path, "POST", handler, errors)
end

macro delete(cfg, path, handler, errors)
    return create_route(cfg, path, "DELETE", handler, errors)
end

macro put(cfg, path, handler, errors)
    return create_route(cfg, path, "PUT", handler, errors)
end

end
