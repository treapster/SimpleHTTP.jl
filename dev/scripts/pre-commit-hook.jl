#!/usr/bin/env -S julia --project=dev

import JuliaFormatter: format_file
import Pkg

function main(_)
    @info "This is git pre-commit hook. Looking for jl files to format..."
    @debug "Using julia project: $(Pkg.project().path)"

    this_file = @__FILE__
    source_file = "scripts/pre-commit-hook.jl"
    @debug "pre-commit debug info" this_file source_file
    diff =
        `diff $this_file $source_file --color=always` |>
        ignorestatus |>
        readchomp
    if diff != ""
        @error "Installed pre-commit hook is stale, run `make pre-commit-install`"
        println(stderr, "\nShowing diff...")
        println(stderr, diff)
        return 1
    end

    staged =
        split(readchomp(`git diff --cached --name-only`), "\n") |>
        filter(isfile)
    unstaged = split(readchomp(`git diff --name-only`), "\n")
    if !isempty(unstaged) && unstaged[1] != ""
        @warn "You have unstaged files!"
    end

    format_diff = .!format_file.(staged; verbose = false)
    if any(format_diff)
        formatted = staged[format_diff]
        @error "Formatted $(sum(format_diff)) jl files:\n$(join(formatted, "\n"))"
        println("\nAborting commit...")
        return 1
    end
    @info "All is fine, commiting..."
    return 0
end

(abspath(PROGRAM_FILE) == @__FILE__) && exit(main(ARGS))
