# Partly translated from the Python crds client; see THIRD_PARTY_NOTICES.md for its copyright and license.
# The public interface: best references (local rules or the server), reference files in the
# cache (downloaded and checked when missing), the parameters a context selects on, and flattening
# a nested header.

# --- reference files --------------------------------------------------------------------------

# How references sit under the references folder: "instrument" (<refs>/<instrument>/<file>) or
# "flat", recorded in config/ref_cache_subdir_mode as by the Python client (which picks "flat" for
# an existing cache of more than 20 entries without that file, else "instrument").
function _ref_subdir_mode(obs)
    p = cache_paths(obs)
    f = joinpath(p.config, "ref_cache_subdir_mode")
    isfile(f) && return strip(read(f, String))
    m = isdir(p.references) && length(readdir(p.references)) > 20 ? "flat" : "instrument"
    write_atomic(f, m)
    return m
end

"""
    reference_path(name; instrument = nothing, observatory = nothing) -> String

Where reference file `name` is (or would be) in the cache.  `instrument` is read from standard
names (`roman_wfi_...`) when not given.
"""
function reference_path(name; instrument = nothing, observatory = nothing)
    obs = observatory === nothing ? observatory_of(name) : check_observatory(observatory)
    m = _ref_subdir_mode(obs)
    m == "flat" && return joinpath(cache_paths(obs).references, name)
    m == "instrument" || throw(CRDSError("unsupported reference cache layout $(repr(m)) in $(cache_paths(obs).config)"))
    if instrument === nothing
        parts = split(name, '_')
        (length(parts) >= 3 && lowercase(parts[1]) == obs) || throw(ArgumentError("cannot tell the instrument of $(repr(name)); pass `instrument`"))
        instrument = parts[2]
    end
    return joinpath(cache_paths(obs).references, lowercase(string(instrument)), name)
end

"Download the references in `files` (name => cache path) that are not cached."
function fetch_references(obs, files, mode)
    todo = [(n, p) for (n, p) in files if !isfile(p)]
    isempty(todo) && return
    _require_contact(obs, "reference files $(join(first.(todo), ", ")) (not in the cache)", mode)
    info = file_info(obs, first.(todo), mode)
    base = _base_url(obs, "reference_url", mode)
    for (n, p) in todo
        haskey(info, n) || throw(CRDSError("the $obs CRDS server does not know $n"))
        fetch_file(obs, base * n, p; mode, size = info[n][1], sha1sum = info[n][2])
    end
end

# --- best references --------------------------------------------------------------------------

function _infer_observatory(header, context, observatory)
    observatory === nothing || return check_observatory(observatory)
    if context !== nothing
        m = match(r"^(hst|jwst|roman)[_\-]", lowercase(string(context)))
        m === nothing || return m.captures[1]
    end
    any(k -> startswith(uppercase(string(k)), "ROMAN."), keys(header)) && return "roman"
    return default_observatory()
end

function _remote_bestrefs(obs, ctx, header, reftypes, mode)
    hdr = Dict{String, String}()
    for (k, v) in header
        (v isa AbstractDict || v isa AbstractVector) && continue
        key = string(k)
        obs == "roman" && startswith(uppercase(key), "META.") && (key = "ROMAN." * key)
        hdr[key] = _pystr(v)
    end
    r = rpc(obs, "get_best_references", ctx, hdr, reftypes === nothing ? nothing : lowercase.(string.(collect(reftypes))); mode)
    out = Dict{String, Tuple{Symbol, String}}()
    for (t, v) in r
        s = string(v)
        out[lowercase(string(t))] = !startswith(s, "NOT FOUND") ? (:found, s) :
            lowercase(strip(s[10:end])) == "n/a" ? (:na, "") : (:failed, strip(s[10:end]))
    end
    return out
end

function _bestrefs(header, context, reftypes, observatory, m)
    check_mode(m)
    obs = _infer_observatory(header, context, observatory)
    ctx = resolve_context(context; observatory = obs, mode = m)
    hdr = condition_header(obs, header)
    if m === :remote || (m === :auto && !(obs in LOCAL_OBSERVATORIES) && can_contact(obs, m))
        try
            return ctx, obs, _remote_bestrefs(obs, ctx, header, reftypes, m), String[ctx], nothing
        catch e
            (m === :auto && e isa CRDSOfflineError) || rethrow()
        end
    end
    m === :auto && !(obs in LOCAL_OBSERVATORIES) &&
        _warn_once("hooks-$obs", "evaluating $obs rules locally (server unreachable): the Python client's $obs selection hooks are not applied, so some types may differ")
    results, used, instr = local_bestrefs(obs, ctx, hdr, reftypes, m)
    unsup = [t for (t, (s, _)) in results if s === :unsupported]
    if !isempty(unsup) && can_contact(obs, m)
        try
            merge!(results, _remote_bestrefs(obs, ctx, header, unsup, m))
        catch e
            e isa CRDSOfflineError || rethrow()
        end
    end
    for t in unsup
        s, why = results[t]
        s === :unsupported && (results[t] = (:failed, "rule not evaluated locally ($why) and the server is not available"))
    end
    return ctx, obs, results, used, instr
end

function _check_bad(obs, names, what, allow_env, mode)
    bad = intersect(Set(names), bad_files(obs, mode))
    isempty(bad) && return
    msg = "$what $(join(sort(collect(bad)), ", ")) marked bad by CRDS"
    env_flag(allow_env) || throw(CRDSError(msg * "; set $allow_env=1 to use anyway"))
    _warn_once("bad-" * join(sort(collect(bad))), msg * " (used because $allow_env is set)")
end

"""
    best_references(header; context = nothing, reftypes = nothing, observatory = nothing,
                    mode = CRDSClient.default_mode(), strict = true) -> Dict{String, String}

Best reference file names for `header`, by reference type (lower case, e.g. `"epsf"`); `"N/A"`
where the rules make a type not applicable.  `header` is flat with the keys the rules use (e.g.
`"ROMAN.META.INSTRUMENT.DETECTOR"`; see [`flatten_header`](@ref) and [`required_parkeys`](@ref)).

- `context`: a `.pmap` (`"roman_0058.pmap"`), `"latest"`/`"operational"`/`"edit"`/`"build"`, or a
  date; default `\$CRDS_CONTEXT`, else latest ([`resolve_context`](@ref)).
- `reftypes`: types to look up (default: all of the instrument's).
- `mode`: `:auto` evaluates the rules locally (Roman, JWST; HST uses the server) and asks the
  server only for rules not supported here; `:local` never contacts the server; `:remote` lets
  the server choose.
- `strict = true` throws a [`CRDSLookupError`](@ref) listing every type without a match and why;
  `false` returns `"NOT FOUND <reason>"` for them instead.

Throws a `CRDSError` when a rule file or a chosen reference is marked bad by CRDS, unless
`CRDS_ALLOW_BAD_RULES` / `CRDS_ALLOW_BAD_REFERENCES` is set.
"""
function best_references(header::AbstractDict; context = nothing, reftypes = nothing, observatory = nothing,
                         mode::Symbol = default_mode(), strict::Bool = true)
    ctx, obs, results, used, _ = _bestrefs(header, context, reftypes, observatory, mode)
    _check_bad(obs, used, "rule files", "CRDS_ALLOW_BAD_RULES", mode)
    out = Dict{String, String}(); failures = Dict{String, String}()
    for (t, (s, v)) in results
        s === :found ? (out[t] = v) : s === :na ? (out[t] = "N/A") : (failures[t] = v)
    end
    _check_bad(obs, collect(values(out)), "reference files", "CRDS_ALLOW_BAD_REFERENCES", mode)
    isempty(failures) || (strict ? throw(CRDSLookupError(ctx, failures)) : merge!(out, Dict(t => "NOT FOUND " * v for (t, v) in failures)))
    return out
end

"""
    get_references(header; context = nothing, reftypes = nothing, observatory = nothing,
                   mode = CRDSClient.default_mode()) -> Dict{String, String}

Local paths of the best references for `header` (as [`best_references`](@ref), strict), by
reference type, downloading (with size and sha1 checks) those not yet cached.  Types that are not
applicable are left out.
"""
function get_references(header::AbstractDict; context = nothing, reftypes = nothing, observatory = nothing, mode::Symbol = default_mode())
    refs = best_references(header; context, reftypes, observatory, mode)
    obs = _infer_observatory(header, context, observatory)
    instr = lowercase(get(condition_header(obs, header), obs == "roman" ? "ROMAN.META.INSTRUMENT.NAME" : "INSTRUME", ""))
    files = Dict(t => reference_path(n; observatory = obs, instrument = _instrument_of(obs, n, instr)) for (t, n) in refs if n != "N/A")
    fetch_references(obs, [(refs[t], p) for (t, p) in files], mode)
    return files
end

_instrument_of(obs, name, fallback) = (p = split(name, '_'); length(p) >= 3 && lowercase(p[1]) == obs ? lowercase(p[2]) :
    isempty(fallback) ? throw(ArgumentError("cannot tell the instrument of $(repr(name))")) : fallback)

"""
    required_parkeys(context = nothing; instrument = nothing, reftypes = nothing, observatory = nothing,
                     mode = CRDSClient.default_mode()) -> Vector{String}

The header keys `context` selects on for `reftypes` (default all) of `instrument` (needed only if
the context has more than one), including the instrument key itself.
"""
function required_parkeys(context = nothing; instrument = nothing, reftypes = nothing, observatory = nothing, mode::Symbol = default_mode())
    check_mode(mode)
    obs = _infer_observatory(Dict(), context, observatory)
    ctx = resolve_context(context; observatory = obs, mode)
    pmap = load_mapping(obs, ctx, mode)
    instr = instrument === nothing ? (length(pmap.imaps) == 1 ? only(keys(pmap.imaps)) :
        throw(ArgumentError("$ctx has instruments $(join(sort(collect(keys(pmap.imaps))), ", ")); pass `instrument`"))) : uppercase(string(instrument))
    imap = load_mapping(obs, pmap.imaps[instr], mode)
    types = reftypes === nothing ? collect(keys(imap.rmaps)) : uppercase.(string.(collect(reftypes)))
    names = [imap.rmaps[t] for t in types if haskey(imap.rmaps, t) && !(imap.rmaps[t] in NA_VALUES) && !(imap.rmaps[t] in OMIT_VALUES)]
    fetch_mappings(obs, names, mode)
    return sort!(unique!(vcat(pmap.instrument_key, (load_mapping(obs, n, mode).parkeys for n in names)...)))
end

"""
    flatten_header(tree; prefix = "") -> Dict{String, Any}

A nested metadata tree (e.g. a Roman file's `meta`, as ASDF.jl returns it) as the flat header
CRDS rules use: dotted, upper-case keys (`flatten_header(meta; prefix = "ROMAN.META")` gives
`"ROMAN.META.EXPOSURE.START_TIME"`), leaf values unchanged; lists are left out.
"""
function flatten_header(tree::AbstractDict; prefix::AbstractString = "")
    out = Dict{String, Any}()
    for (k, v) in tree
        key = isempty(prefix) ? uppercase(string(k)) : uppercase(prefix) * "." * uppercase(string(k))
        if v isa AbstractDict
            merge!(out, flatten_header(v; prefix = key))
        elseif !(v isa AbstractVector)
            out[key] = v
        end
    end
    return out
end
