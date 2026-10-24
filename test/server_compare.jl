# Comparing local rule evaluation with the CRDS server.  Headers are drawn from the values a
# context's own rules list (plus undefined keys and values no rule lists), dates around every
# UseAfter boundary and versions around every VersionAfter one; the server answers through its
# batch RPC, for an explicit list of every reference type of the context's instruments (with no
# list, the Python client narrows JWST lookups to its pipeline's types).  For JWST, headers can
# also be sent with FITS keywords (`fits = true`), which checks the FITS keyword table against the
# server's own data-model translation.  Used by the live tests (runtests.jl), and by hand for wider
# checks, e.g. `compare_contexts(contexts; obs = "jwst", n = 200)` over a context history.

using CRDSClient, Random
using CRDSClient: MatchSelector, UseAfterSelector, VersionAfterSelector, load_mapping, glob_list, esoteric_key, rpc,
                  JWST_FITS_TO_DM, NA_VALUES, OMIT_VALUES

# Rule values per header key (`vals`), UseAfter dates per parameter tuple (`dates`), versions per
# VersionAfter parameter (`vers`).
function _collect!(acc, s::MatchSelector)
    for (i, p) in enumerate(s.parameters), e in s.entries
        for v in glob_list(e.key[i])
            (esoteric_key(v) || occursin('*', v) || v == "N/A") || push!(get!(acc.vals, p, Set{String}()), v)
        end
    end
    foreach(e -> _collect!(acc, e.choice), s.entries)
end
function _collect!(acc, s::UseAfterSelector)
    union!(get!(acc.dates, Tuple(s.parameters), Set{String}()), s.keys)
    foreach(c -> _collect!(acc, c), s.choices)
end
function _collect!(acc, s::VersionAfterSelector)
    union!(get!(acc.vers, only(s.parameters), Set{String}()), (join(k, ".") for k in s.keys))
    foreach(c -> _collect!(acc, c), s.choices)
end
_collect!(acc, ::Any) = nothing

"Rule values of context `ctx`, and every reference type of its instruments."
function rule_values(ctx; obs = "roman")
    pmap = load_mapping(obs, ctx, :auto)
    acc = (; vals = Dict{String, Set{String}}(), dates = Dict{Tuple, Set{String}}(), vers = Dict{String, Set{String}}())
    types = Set{String}()
    for (instr, iname) in pmap.imaps
        push!(get!(acc.vals, pmap.instrument_key, Set{String}()), instr)
        imap = load_mapping(obs, iname, :auto)
        union!(types, lowercase.(keys(imap.rmaps)))
        names = [r for r in values(imap.rmaps) if !(r in NA_VALUES) && !(r in OMIT_VALUES)]
        CRDSClient.fetch_mappings(obs, names, :auto)
        foreach(r -> _collect!(acc, load_mapping(obs, r, :auto).selector), names)
    end
    return acc, sort!(collect(types))
end

function _shift(date, seconds)
    d = CRDSClient.Dates.DateTime(replace(first(date, 19), ' ' => 'T')) + CRDSClient.Dates.Second(seconds)
    return CRDSClient.Dates.format(d, "yyyy-mm-dd HH:MM:SS")
end

function _bump(v, k)        # a version one step away in component k (never below 0)
    p = collect(parse.(Int, split(v, '.')))
    p[k] = max(0, p[k] + rand((-1, 1)))
    return join(p, ".")
end

"""
`n` random headers for `ctx`: each key a listed value (80 %), missing (10 %) or unlisted (10 %);
dates and versions at or next to rule boundaries.  Also returns every reference type of the context.
"""
function sample_headers(ctx, n; rng = Random.Xoshiro(1), obs = "roman")
    acc, types = rule_values(ctx; obs)
    alld = sort!(collect(union(Set{String}(), values(acc.dates)...)))
    dpool = unique!(vcat(alld, _shift.(alld, -1), _shift.(alld, 1), ["2019-06-01 00:00:00", "2026-10-02 03:25:39.356", "2031-01-01 00:00:00"]))
    keyvals = Dict(k => sort!(collect(v)) for (k, v) in acc.vals)
    instr_key = load_mapping(obs, ctx, :auto).instrument_key
    headers = Dict{String, String}[]
    for _ in 1:n
        h = Dict{String, String}()
        for (k, vs) in keyvals
            r = rand(rng)
            (k == instr_key || r < 0.8) ? (h[k] = rand(rng, vs)) : r < 0.9 ? nothing : (h[k] = "BOGUS_VALUE")
        end
        for params in keys(acc.dates)            # one date, split over the parameters (date, time)
            any(in(keys(keyvals)), params) && continue
            rand(rng) < 0.95 || continue
            parts = split(rand(rng, dpool), ' '; limit = length(params))
            for (p, v) in zip(params, parts); h[p] = v; end
        end
        for (p, vs) in acc.vers
            v = rand(rng, sort!(collect(vs)))
            r = rand(rng)
            h[p] = r < 0.4 ? v : r < 0.8 ? _bump(v, rand(rng, 1:3)) : r < 0.9 ? v * "rc1.dev12+gabc" : "UNDEFINED"
        end
        push!(headers, h)
    end
    return headers, types
end

const _DM_TO_FITS = Dict(v => k for (k, v) in JWST_FITS_TO_DM)

"`h` with data-model keys replaced by their FITS keywords where the table has one (JWST)."
fits_form(h) = Dict(get(_DM_TO_FITS, k, k) => v for (k, v) in h)

"""
Server answers for `headers` in `ctx` and `reftypes`: one Dict(reftype => answer string) per
header, or Dict("*" => message) when the server could not evaluate the header (e.g. no instrument).
"""
function server_answers(ctx, headers, reftypes; obs = "roman", batch = 500)
    out = Vector{Dict{String, String}}(undef, length(headers))
    for r in Iterators.partition(eachindex(headers), batch)
        res = rpc(obs, "get_best_references_by_header_map", ctx, Dict(string(i) => headers[i] for i in r), reftypes; mode = :auto)
        for (k, (ok, refs)) in res
            out[parse(Int, k)] = ok ? Dict(lowercase(string(t)) => string(v) for (t, v) in refs) : Dict("*" => string(refs))
        end
    end
    return out
end

# Server answer string and local answer in one vocabulary: a file name, "N/A" or "FAIL".
_norm_server(s) = !startswith(s, "NOT FOUND") ? s : lowercase(strip(s[10:end])) == "n/a" ? "N/A" : "FAIL"
_norm_local(s) = startswith(s, "NOT FOUND") ? "FAIL" : s

"Mismatches between local evaluation and `answers`: (header, reftype, local, server)."
function compare(ctx, headers, answers, reftypes; obs = "roman")
    bad = Tuple{Dict{String, String}, String, String, String}[]
    for (h, a) in zip(headers, answers)
        loc = try
            best_references(h; context = ctx, observatory = obs, reftypes, mode = :local, strict = false)
        catch e
            e isa CRDSError || rethrow()
            Dict("*" => sprint(showerror, e))       # the whole header rejected
        end
        if haskey(a, "*") || haskey(loc, "*")
            haskey(a, "*") && haskey(loc, "*") || push!(bad, (h, "*", get(loc, "*", "(answered)"), get(a, "*", "(answered)")))
            continue
        end
        for t in union(keys(loc), keys(a))
            l = _norm_local(get(loc, t, "(absent)")); s = _norm_server(get(a, t, "(absent)"))
            l == s || push!(bad, (h, t, get(loc, t, "(absent)"), get(a, t, "(absent)")))
        end
    end
    return bad
end

"Compare `n` sampled headers in each of `contexts`; with `fits`, every other header in FITS form."
function compare_contexts(contexts; obs, n = 300, fits = false, io = stdout)
    tot = nbad = nrej = 0
    for ctx in contexts
        hs, types = sample_headers(ctx, n; rng = Random.Xoshiro(hash(ctx)), obs)
        fits && (hs = [isodd(i) ? fits_form(h) : h for (i, h) in enumerate(hs)])
        ans = server_answers(ctx, hs, types; obs)
        bad = compare(ctx, hs, ans, types; obs)
        nrej += count(a -> haskey(a, "*"), ans); tot += sum(length, ans); nbad += length(bad)
        isempty(bad) || (println(io, ctx, ": ", length(bad), " mismatches");
                         foreach(b -> println(io, "   ", b[2], " local=", b[3], " server=", b[4], "\n      ", b[1]), first(bad, 3)))
    end
    println(io, "$obs: $tot answers over $(length(contexts)) contexts ($nrej headers rejected whole by the server), $nbad mismatches")
    return nbad
end
