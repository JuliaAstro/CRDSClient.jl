# Translated from the Python crds client; see THIRD_PARTY_NOTICES.md for its copyright and license.
# Errors, observatories, server URLs, cache locations and runtime settings.  Environment variables
# follow the Python crds client so both can share one setup and one cache.

"A CRDS failure: a server error, a malformed mapping, a failed download or check, ..."
struct CRDSError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CRDSError) = print(io, "CRDSError: ", e.msg)

"The server was needed (files not cached, or remote lookups) but could not be reached."
struct CRDSOfflineError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CRDSOfflineError) = print(io, "CRDSOfflineError: ", e.msg)

"""
One or more reference types had no best reference.  `failures` maps each such type to the reason
(e.g. which header parameter had a value the rules do not list).
"""
struct CRDSLookupError <: Exception
    context::String
    failures::Dict{String, String}
end
function Base.showerror(io::IO, e::CRDSLookupError)
    print(io, "CRDSLookupError: no best reference in ", e.context, " for ", join(sort(collect(keys(e.failures))), ", "))
    for (k, v) in sort(collect(e.failures))
        print(io, "\n  ", k, ": ", v)
    end
end

# A rule this package does not evaluate locally (a selector class or rmap header feature); the
# lookup goes to the server instead in `:auto` mode.
struct UnsupportedRule <: Exception
    msg::String
end
Base.showerror(io::IO, e::UnsupportedRule) = print(io, "UnsupportedRule: ", e.msg)

const OBSERVATORIES = ("hst", "jwst", "roman")
const DEFAULT_SERVERS = Dict("hst" => "https://hst-crds.stsci.edu", "jwst" => "https://jwst-crds.stsci.edu",
                             "roman" => "https://roman-crds.stsci.edu")
# Observatories whose rules are evaluated locally by default: their rmaps use only features this
# package implements, checked against the servers (test/server_compare.jl; 2026-10-24: Roman, all 68
# contexts, 604,500 answers; JWST, 50 of 554 contexts, 1,019,800 answers with data-model keys and
# again with FITS keywords; 0 mismatches).  HST rules contain Python expressions and the Python
# client applies selection hooks for HST, neither reproduced here, so HST lookups always go to the
# server (an error when it cannot be used).
const LOCAL_OBSERVATORIES = ("roman", "jwst")

"Seconds allowed to establish a connection to the server (not the transfer)."
const CONNECT_TIMEOUT = Ref(5.0)
"Stored server information (current contexts, bad files) older than this is refreshed when online."
const SERVER_INFO_MAX_AGE = Ref(Dates.Hour(24))

function check_observatory(obs)
    o = lowercase(string(obs))
    o in OBSERVATORIES || throw(ArgumentError("unknown observatory $(repr(obs)); expected one of $(OBSERVATORIES)"))
    return o
end

"Server URL for `observatory`: `\$CRDS_SERVER_URL`, else the observatory's STScI server."
server_url(obs) = rstrip(get(ENV, "CRDS_SERVER_URL", DEFAULT_SERVERS[obs]), '/')

"""
    default_mode() -> Symbol

`:auto` (default), `:local` (never contact the server) or `:remote` (the server chooses
references), from `\$CRDS_MODE` as in the Python client.  The default of every `mode` keyword.
"""
function default_mode()
    m = lowercase(get(ENV, "CRDS_MODE", "auto"))
    m in ("auto", "local", "remote") || throw(ArgumentError("CRDS_MODE must be auto, local or remote, got $(repr(m))"))
    return Symbol(m)
end

check_mode(m) = m in (:auto, :local, :remote) ? m : throw(ArgumentError("mode must be :auto, :local or :remote, got $(repr(m))"))

env_flag(name) = lowercase(strip(get(ENV, name, "false"))) in ("1", "true", "t", "yes", "y", "on")

scratch_cache() = @get_scratch!("crds_cache")

# The Python client's `_std_cache_path`, first definition winning, e.g. for mappings:
# CRDS_MAPPATH_SINGLE, CRDS_MAPPATH/<obs>, CRDS_PATH_SINGLE/mappings, CRDS_PATH/mappings/<obs>,
# CRDS_DEFAULT_CACHE/mappings/<obs>; then (instead of the client's /grp/crds/cache) this
# package's scratch space.
function std_cache_path(obs, root_env, subdir)
    p = haskey(ENV, root_env * "_SINGLE") ? ENV[root_env * "_SINGLE"] :
        haskey(ENV, root_env) ? joinpath(ENV[root_env], obs) :
        haskey(ENV, "CRDS_PATH_SINGLE") ? joinpath(ENV["CRDS_PATH_SINGLE"], subdir) :
        haskey(ENV, "CRDS_PATH") ? joinpath(ENV["CRDS_PATH"], subdir, obs) :
        haskey(ENV, "CRDS_DEFAULT_CACHE") ? joinpath(ENV["CRDS_DEFAULT_CACHE"], subdir, obs) :
        joinpath(scratch_cache(), subdir, obs)
    return rstrip(expanduser(p), '/')
end

"""
    cache_paths(observatory) -> NamedTuple

Where mappings, references and configuration of `observatory` are cached: the Python client's
layout under `\$CRDS_PATH` (or its other `CRDS_*PATH*` variables), else this package's scratch
space.
"""
cache_paths(obs) = (o = check_observatory(obs);
    (; mappings = std_cache_path(o, "CRDS_MAPPATH", "mappings"), references = std_cache_path(o, "CRDS_REFPATH", "references"),
     config = std_cache_path(o, "CRDS_CFGPATH", "config")))

"Observatory of a mapping or reference name such as `roman_0072.pmap`."
function observatory_of(name)
    o = lowercase(first(split(basename(name), r"[_\-.]")))
    o in OBSERVATORIES || throw(ArgumentError("cannot tell the observatory of $(repr(name)); pass `observatory`"))
    return o
end
