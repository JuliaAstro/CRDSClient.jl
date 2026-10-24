# Translated from the Python crds client; see THIRD_PARTY_NOTICES.md for its copyright and license.
# Mappings: a context (.pmap) selects an instrument mapping (.imap) by instrument, which names
# one reference mapping (.rmap) per reference type, whose selector tree picks the file.  Mapping
# files are immutable once published, so a cached copy is always valid; missing ones are
# downloaded (checked against the server's size and sha1) when the server can be reached.

const NA_VALUES = ("N/A", "TEMP_N/A", "n/a", "temp_n/a")
# The Python client's fallbacks when the header lacks a context's instrument key (constants.py).
const INSTRUMENT_KEYWORDS = ("INSTRUME", "META.INSTRUMENT.NAME", "META_INSTRUMENT_NAME", "INSTRUMENT", "ROMAN.META.INSTRUMENT.NAME",
                             "META.INSTRUMENT.TYPE", "META_INSTRUMENT_TYPE")
const OMIT_VALUES = ("OMIT", "TEMP_OMIT", "omit")

struct PipelineMapping
    name::String
    header::Dict{Any, Any}
    instrument_key::String
    imaps::Dict{String, String}         # INSTRUMENT => .imap
end

struct InstrumentMapping
    name::String
    header::Dict{Any, Any}
    instrument::String
    rmaps::Dict{String, String}         # REFTYPE => .rmap, or N/A / OMIT
end

struct ReferenceMapping
    name::String
    header::Dict{Any, Any}
    instrument::String
    filekind::String
    parkeys::Vector{String}             # every header key the rules read
    selector::Any
    unsupported::Union{Nothing, String} # an rmap header feature not evaluated here
    reffile_required::String
end

# rmap header features of the Python client that this package does not evaluate (expressions in
# Python, instrument-package hooks); a mapping using one is left to the server.
function _unsupported_feature(h)
    rel = lowercase(strip(string(get(h, "rmap_relevance", "always"))))
    rel in ("always", "(true)", "true") || return "rmap_relevance $(repr(h["rmap_relevance"]))"
    omit = lowercase(strip(string(get(h, "rmap_omit", "false"))))
    omit in ("false", "(false)") || return "rmap_omit $(repr(h["rmap_omit"]))"
    isempty(get(h, "parkey_relevance", Dict())) || return "parkey_relevance"
    isempty(get(h, "hooks", Dict())) || return "hooks"
    uppercase(string(get(h, "reffile_switch", "NONE"))) == "NONE" || return "reffile_switch"
    return nothing
end

function parse_mapping(name, text; source = name)
    a = parse_assignments(text; source)
    (haskey(a, "header") && haskey(a, "selector")) || throw(CRDSError("$source is not a CRDS mapping (no header or selector)"))
    h = a["header"]
    string(get(h, "name", name)) == name || throw(CRDSError("$source names itself $(repr(h["name"]))"))
    kind = uppercase(string(get(h, "mapping", "")))
    sel = a["selector"]
    if kind == "PIPELINE"
        pk = h["parkey"]
        return PipelineMapping(name, h, uppercase(string(pk isa Tuple ? pk[1] : pk)), Dict(uppercase(string(k)) => string(v) for (k, v) in sel))
    elseif kind == "INSTRUMENT"
        return InstrumentMapping(name, h, uppercase(string(h["instrument"])), Dict(uppercase(string(k)) => string(v) for (k, v) in sel))
    elseif kind == "REFERENCE"
        pk = h["parkey"]
        levels = pk isa Tuple && !isempty(pk) && first(pk) isa AbstractString ? (pk,) : pk   # one level or several
        keys = String[uppercase(string(p)) for lev in levels for p in lev]
        append!(keys, uppercase.(string.(collect(get(h, "extra_keys", ())))))
        levels = Tuple(Tuple(uppercase(string(p)) for p in lev) for lev in levels)
        return ReferenceMapping(name, h, uppercase(string(h["instrument"])), lowercase(string(h["filekind"])), unique!(keys),
                                build_selector(sel, levels, h), _unsupported_feature(h), uppercase(string(get(h, "reffile_required", "NONE"))))
    end
    throw(CRDSError("$source: unknown mapping type $(repr(kind))"))
end

const MAPPINGS = Dict{Tuple{String, String}, Any}()
const MAP_LOCK = ReentrantLock()

mapping_path(obs, name) = joinpath(cache_paths(obs).mappings, name)

_base_url(obs, which, mode) = (u = get(get(server_info(obs; mode), which, Dict()), "unchecked", Dict());
    b = haskey(u, obs) ? string(u[obs]) : server_url(obs) * "/unchecked_get/$(replace(which, "_url" => "s"))/$obs/";
    endswith(b, "/") ? b : b * "/")

"Download the mappings in `names` that are not cached (one file-info call for all of them)."
function fetch_mappings(obs, names, mode)
    missing_names = filter(n -> !isfile(mapping_path(obs, n)), unique(names))
    isempty(missing_names) && return
    _require_contact(obs, "rule files $(join(missing_names, ", ")) (not in the cache)", mode)
    info = file_info(obs, missing_names, mode)
    base = _base_url(obs, "mapping_url", mode)
    for n in missing_names
        haskey(info, n) || throw(CRDSError("the $obs CRDS server does not know $n"))
        fetch_file(obs, base * n, mapping_path(obs, n); mode, size = info[n][1], sha1sum = info[n][2])
    end
end

"The parsed mapping `name` of `obs`, downloading it if it is not cached (and `mode` allows)."
function load_mapping(obs, name, mode)
    m = lock(() -> get(MAPPINGS, (obs, name), nothing), MAP_LOCK)
    m === nothing || return m
    # parsed outside the lock (fetch_mappings locks the file itself); two threads may both parse
    # a mapping the first time, and the first stored wins
    path = mapping_path(obs, name)
    isfile(path) || fetch_mappings(obs, [name], mode)
    m = parse_mapping(name, read(path, String); source = path)
    return lock(() -> get!(MAPPINGS, (obs, name), m), MAP_LOCK)
end

"""
    condition_header(obs, header) -> Dict{String, String}

`header` (flat, e.g. from `flatten_header`) with upper-case keys and conditioned values, in the
keys the rules use (as the Python client does): for Roman, `META.` keys get the `ROMAN.` prefix; for
JWST, FITS keywords become data-model paths (jwst.jl), an explicit data-model key winning over a
FITS keyword that maps to it.
"""
function condition_header(obs, header::AbstractDict)
    out = Dict{String, String}()
    translated = Dict{String, String}()
    for (k, v) in header
        (v isa AbstractDict || v isa AbstractVector) && continue
        key = uppercase(string(k))
        obs == "roman" && startswith(key, "META.") && (key = "ROMAN." * key)
        if obs == "jwst" && !startswith(key, "META.")
            translated[jwst_parkey(key)] = condition_value(v)
        else
            out[key] = condition_value(v)
        end
    end
    for (k, v) in translated
        haskey(out, k) || (out[k] = v)
    end
    return out
end

# One rmap's verdict: (:found, file), (:na, ""), (:omit, ""), (:failed, why) or (:unsupported, why).
function evaluate(r::ReferenceMapping, header)
    r.unsupported === nothing || return (:unsupported, "$(r.name) uses $(r.unsupported)")
    choice = try
        choose(r.selector, header)
    catch e
        e isa UnsupportedRule && return (:unsupported, "$(r.name): $(e.msg)")
        e isa Union{LookupFailure, ValidationFailure} || rethrow()
        # a type the rules mark as optional is not applicable when nothing matches
        r.reffile_required in ("YES", "NONE") || return (:na, "")
        return (:failed, e.msg)
    end
    choice in NA_VALUES && return (:na, "")
    choice in OMIT_VALUES && return (:omit, "")
    return (:found, choice)
end

"""
Local best references of `reftypes` (all of the instrument's if `nothing`) in context `ctx` for
conditioned `header`: `Dict(reftype => (status, value))`, the mappings used, and the instrument.
"""
function local_bestrefs(obs, ctx, header, reftypes, mode)
    pmap = load_mapping(obs, ctx, mode)
    pmap isa PipelineMapping || throw(ArgumentError("$ctx is not a pipeline context"))
    # the context's instrument key, else the Python client's fallback keywords
    k = findfirst(k -> get(header, k, "UNDEFINED") != "UNDEFINED", [pmap.instrument_key; INSTRUMENT_KEYWORDS...])
    k === nothing && throw(CRDSError("the header has no $(pmap.instrument_key) (the instrument), which $ctx selects on"))
    instr = header[[pmap.instrument_key; INSTRUMENT_KEYWORDS...][k]]
    haskey(pmap.imaps, instr) || throw(CRDSError("$ctx has no instrument $(repr(instr)) (it has $(join(sort(collect(keys(pmap.imaps))), ", ")))"))
    imap = load_mapping(obs, pmap.imaps[instr], mode)
    types = reftypes === nothing ? sort!(collect(keys(imap.rmaps))) : unique!(uppercase.(string.(collect(reftypes))))
    wanted = [imap.rmaps[t] for t in types if haskey(imap.rmaps, t) && !(imap.rmaps[t] in NA_VALUES) && !(imap.rmaps[t] in OMIT_VALUES)]
    fetch_mappings(obs, wanted, mode)
    results = Dict{String, Tuple{Symbol, String}}()
    used = String[ctx, imap.name]
    for t in types
        r = get(imap.rmaps, t, nothing)
        if r === nothing
            results[lowercase(t)] = (:failed, "$(imap.name) has no reference type $(repr(lowercase(t)))")
        elseif r in NA_VALUES
            results[lowercase(t)] = (:na, "")
        elseif !(r in OMIT_VALUES)
            push!(used, r)
            results[lowercase(t)] = evaluate(load_mapping(obs, r, mode), header)
        end
    end
    filter!(p -> p.second[1] !== :omit, results)
    return results, used, lowercase(imap.instrument)
end
