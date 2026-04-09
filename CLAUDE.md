# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Style

### Git

- Use conventional commit namings
- Write comprehensive, yet succint commit summaries that support commit name and diff, without utterly describing it

## Commands

```bash
make test          # Run tests (failfast=true, verbose=true by default)
make format        # Format all Julia files with JuliaFormatter
make repl          # Start Julia REPL with project loaded
make clean         # Remove tmp/ and test/tmp/
make init-dev      # Initialize dev environment (needed for format)
make pre-commit-install   # Install git pre-commit hooks
```

Test environment variables (override via env or `Makefile.local`):

- `JULIA_TEST_FAILFAST` — default `true`
- `JULIA_TEST_VERBOSE` — default `true`

Formatting is configured in `.JuliaFormatter.toml` (4-space indent, 80-char margin, trailing commas).

## Architecture

The package provides macro-driven HTTP server and client abstractions, eliminating boilerplate type definitions via metaprogramming.

**Module structure:**

- `SimpleHTTP` (entry: [src/SimpleHTTP.jl](src/SimpleHTTP.jl)) — re-exports `Server`, `Client`, `HTTP`, `ServerConfig`, `ClientConfig`, `@ip_str`, `IPAddr`
- `Common` ([src/Common.jl](src/Common.jl)) — shared utilities: `ParamData`, `ArgLoc` enum, JSON serialization (`write_json`/`read_json`), `parse_params`, `ErrorResponse`
- `Server` ([src/Server.jl](src/Server.jl)) — HTTP server submodule
- `Client` ([src/Client.jl](src/Client.jl)) — HTTP client submodule

**Core design — macro-driven route definitions:**

Both `Server` and `Client` expose `@get`, `@post`, `@put`, `@delete` macros that take a config, path, and function signature. At expansion time, they:

1. Parse the function signature's type annotations to determine how each argument maps to the request (`parse_params` in `Common`)
2. Generate a handler (server) or request function (client) with all parameter extraction/serialization wired in

**Parameter type annotation conventions** (declared in function signatures):

- Plain type (e.g., `::Int`) → query parameter (or URL param if `{argname}` appears in path)
- `Json{T}` → full request/response body deserialized as `T`
- `JsonField{T}` → individual field from a JSON body
- `Headers` → all request headers as `Dict{String,String}`
- `Headers["key"]` → specific header by name (lowercased)
- Default values (`= val`) make parameters optional

**Server macro signature:**

```julia
Server.@get(cfg, "/path/{id}", function route_name(id::String, q::Int = 0)::RetType
    # body
end, error_codes_dict)
```

**Client macro signature:**

```julia
Client.@get(cfg, "/path/{id}", route_name(id::String, q::Int = 0)::RetType, error_codes_dict)
```

**Error handling:**

- Server: `error_codes` is a `Dict{Type,Int}` mapping exception types → HTTP status codes. Unmapped exceptions → 500 (body controlled by `verbosity_500`). Mapped exceptions are serialized via `Common.serialize`.
- Client: `err_map` is a `Dict{Int,Type}` mapping HTTP status codes → exception types. Unmapped non-2xx → `Client.UnexpectedResponseError`. Matched statuses → `deserialize(resp.body, type)`.

**Response codes:**

- `200` — successful response with body
- `204` — handler returns `Nothing`
- `422` — parameter/body parsing failure

**Serialization:** JSON3 with `allow_inf=true`. Error responses use `ErrorResponse` struct with a single `error::String` field.

**Tests** ([test/](test/)) use a live server (`Server.serve!`) with a `ServerTest` module defining actual routes and a `ClientTest` module defining the matching client calls, then exercise them end-to-end.
