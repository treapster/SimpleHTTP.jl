#!/usr/bin/env -S julia --project=dev

import Pkg

function main(args)
    @assert length(args) == 2 "pass `project_file` and patch `type`"
    project_file = args[1]
    type = args[2]

    project = Pkg.Types.read_project("Project.toml")
    old_version = project.version
    new_version = if type == "--major"
        Base.nextmajor(project.version)
    elseif type == "--minor"
        Base.nextminor(project.version)
    elseif type == "--patch"
        Base.nextpatch(project.version)
    elseif type == "--prerelease"
        nextprerelease(project.version)
    else
        throw(ArgumentError("type `$type` is not supported"))
    end
    project.version = new_version
    Pkg.Types.write_project(project, project_file)
    println(
        "Bumped project version in $project_file from v$old_version to v$new_version",
    )

    return 0
end

function thisprerelease(v::VersionNumber)
    return VersionNumber(v.major, v.minor, v.patch, v.prerelease)
end

function nextprerelease(v::VersionNumber)
    return if v < thisprerelease(v)
        thisprerelease(v)
    else
        @assert length(v.prerelease) == 2 "only prerelease versions like `rc.1` are supported"
        VersionNumber(
            v.major,
            v.minor,
            v.patch,
            (v.prerelease[1], v.prerelease[2] + 1),
        )
    end
end

(abspath(PROGRAM_FILE) == @__FILE__) && exit(main(ARGS))
