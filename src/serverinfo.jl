# Server information (current contexts, context history, bad files, download URLs) and context
# resolution.  It is refreshed from the server when the stored copy is older than
# SERVER_INFO_MAX_AGE and the server can be reached, and stored as JSON in the cache's config
# folder; offline, the stored copy (or the Python client's `server_config`) is used.

const SESSION_INFO = Dict{String, Dict{String, Any}}()
const INFO_LOCK = ReentrantLock()       # SESSION_INFO, and one refresh at a time
const INFO_KEYS = ("observatory", "operational_context", "latest_context", "edit_context", "build_context",
                   "bad_files_list", "context_history", "mapping_url", "reference_url", "crds_version", "last_synced")
const WARNED = Set{String}()
const WARNED_LOCK = ReentrantLock()

_info_file(obs) = joinpath(cache_paths(obs).config, "crdsclient_server_info.json")

function _warn_once(key, msg)
    lock(() -> (key in WARNED ? false : (push!(WARNED, key); true)), WARNED_LOCK) && @warn msg
    return nothing
end

# Stored server information: ours, else the Python client's server_config (a Python literal).
function _stored_info(obs)
    for (path, reader) in ((_info_file(obs), p -> JSON.parse(read(p, String))),
                           (joinpath(cache_paths(obs).config, "server_config"), p -> parse_literal(read(p, String); source = p)))
        isfile(path) || continue
        info = try
            reader(path)
        catch e
            @warn "ignoring unreadable CRDS server information $path" exception = e
            continue
        end
        return (; info = Dict{String, Any}(string(k) => v for (k, v) in info), time = Dates.unix2datetime(mtime(path)), path)
    end
    return nothing
end

"""
    server_info(observatory; refresh = false, mode = CRDSClient.default_mode()) -> Dict

The CRDS server's information for `observatory`: `latest_context`, `operational_context`,
`edit_context`, `build_context`, `context_history`, `bad_files_list`, download URLs.  Read from the
cache when it is younger than `CRDSClient.SERVER_INFO_MAX_AGE[]` (or the server is unreachable),
else fetched; `refresh = true` fetches when possible.  `mode = :local` never contacts the server.
A read-only cache (`CRDS_READONLY_CACHE`) keeps the information it holds, however old (except with
`refresh` or `mode = :remote`), so `"latest"` names the newest context it was filled with.
"""
function server_info(observatory; refresh::Bool = false, mode::Symbol = default_mode())
    obs = check_observatory(observatory)
    lock(() -> _server_info(obs, refresh, check_mode(mode)), INFO_LOCK)
end

function _server_info(obs, refresh, mode)
    !refresh && haskey(SESSION_INFO, obs) && return SESSION_INFO[obs]
    stored = _stored_info(obs)
    # a read-only cache keeps its own server information, as in the Python client, so its "latest"
    # context is one whose rules it holds
    fresh = stored !== nothing && ((readonly_cache() && mode !== :remote) || Dates.now(Dates.UTC) - stored.time < SERVER_INFO_MAX_AGE[])
    if (refresh || !fresh) && can_contact(obs, mode)
        try
            info = rpc(obs, "get_server_info"; mode)
            lowercase(string(info["observatory"])) == obs ||
                throw(CRDSError("$(server_url(obs)) is the CRDS server for $(info["observatory"]), not $obs; check CRDS_SERVER_URL"))
            info = Dict{String, Any}(k => info[k] for k in INFO_KEYS if haskey(info, k))
            save_config(_info_file(obs), JSON.json(info))
            return SESSION_INFO[obs] = info
        catch e
            e isa CRDSOfflineError || rethrow()
        end
    end
    stored === nothing && throw(CRDSOfflineError("no stored CRDS server information for $obs and the server cannot be contacted"))
    fresh || _warn_once("info-$obs", "using CRDS server information for $obs stored $(Dates.canonicalize(Dates.round(Dates.now(Dates.UTC) - stored.time, Dates.Minute))) ago ($(stored.path))")
    return SESSION_INFO[obs] = stored.info
end

"Names of files the server has marked bad (empty, with a warning, if no information is available)."
function bad_files(obs, mode)
    info = try
        server_info(obs; mode)
    catch e
        e isa CRDSOfflineError || rethrow()
        _warn_once("bad-$obs", "no CRDS server information for $obs: bad reference and rule files cannot be checked")
        return Set{String}()
    end
    return Set{String}(string.(get(info, "bad_files_list", String[])))
end

"""
    default_observatory() -> String

`\$CRDS_OBSERVATORY`, else the observatory named in `\$CRDS_SERVER_URL` (e.g.
`https://roman-crds.stsci.edu`).
"""
function default_observatory()
    haskey(ENV, "CRDS_OBSERVATORY") && return check_observatory(ENV["CRDS_OBSERVATORY"])
    m = match(r"//(hst|jwst|roman)[-.]", lowercase(get(ENV, "CRDS_SERVER_URL", "")))
    m === nothing && throw(ArgumentError("no observatory given: pass `observatory`, a context such as \"roman_0072.pmap\", or set CRDS_OBSERVATORY"))
    return m.captures[1]
end

"""
    resolve_context(context = nothing; observatory = nothing, mode = CRDSClient.default_mode()) -> String

The literal `.pmap` that `context` names:
- a `.pmap` name (`"roman_0058.pmap"`) is returned as is;
- `"latest"`, `"operational"`, `"edit"`, `"build"` (optionally prefixed, `"roman-latest"`) come from
  the server information;
- a date (`"roman-2026-10-01"`, `"2026-10-01T12:00:00"`) gives the context that was current then
  (from the server's context history);
- `nothing` uses `\$CRDS_CONTEXT`, else `"latest"`.
"""
function resolve_context(context = nothing; observatory = nothing, mode::Symbol = default_mode())
    ctx = context === nothing ? get(ENV, "CRDS_CONTEXT", "latest") : string(context)
    pre = match(r"^(hst|jwst|roman)[_\-]", lowercase(ctx))
    obs = observatory !== nothing ? check_observatory(observatory) : pre !== nothing ? pre.captures[1] : default_observatory()
    pre === nothing || pre.captures[1] == obs || throw(ArgumentError("context $(repr(ctx)) is not a $obs context"))
    if endswith(ctx, ".pmap")
        return ctx
    elseif endswith(ctx, ".imap") || endswith(ctx, ".rmap")
        throw(ArgumentError("context must be a pipeline context (.pmap), got $(repr(ctx))"))
    end
    rest = pre === nothing ? ctx : ctx[length(pre.match) + 1:end]
    state = lowercase(rest)
    if state in ("latest", "operational", "edit", "build", "versions")
        c = get(server_info(obs; mode), state * "_context", "")
        isempty(c) && throw(CRDSError("the $obs server reports no $state context"))
        return String(c)
    end
    return context_by_date(obs, rest, mode)
end

"The context that was current at `date` (any format `reformat_date` reads), from the context history."
function context_by_date(obs, date, mode)
    d = reformat_date(date)
    best = nothing
    for (when, pmap) in ((reformat_date(replace(string(h[1]), r"[+-]\d\d:\d\d$" => "")), string(h[2])) for h in server_info(obs; mode)["context_history"])
        when <= d && (best === nothing || when > best[1]) && (best = (when, pmap))
    end
    best === nothing && throw(CRDSError("no $obs context was current at $d"))
    return best[2]
end
