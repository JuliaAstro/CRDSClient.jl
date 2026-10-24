# Translated from the Python crds client; see THIRD_PARTY_NOTICES.md for its copyright and license.
# Selectors: the rules inside an .rmap.  A port of the lookup half of the Python client's
# crds/core/selectors.py (MatchSelector, UseAfterSelector and the matchers), including its value
# conditioning (crds/core/utils.py: condition_value) and date normalization
# (crds/core/timestamp.py: reformat_date).  Rule editing, diffing and validation against .tpn
# files are not ported.

# A candidate that cannot match (no clause, no date): the next candidate is tried.  The Python
# client's CrdsLookupError family.
struct LookupFailure <: Exception
    msg::String
end
# A header the rules reject outright (e.g. a value no clause lists).  Its ValidationError.
struct ValidationFailure <: Exception
    msg::String
end

# --- values -----------------------------------------------------------------------------------

_pystr(v::AbstractString) = String(v)
_pystr(v::Bool) = v ? "True" : "False"
_pystr(::Nothing) = "None"
_pystr(v) = string(v)
_pyrepr(s) = "'" * replace(String(s), "\\" => "\\\\", "'" => "\\'") * "'"

"Python's `repr` of a float (shortest round-trip digits, its switch to exponent notation)."
function pyfloatstr(x::Float64)
    isnan(x) && return "nan"
    isinf(x) && return x > 0 ? "inf" : "-inf"
    x == 0 && return signbit(x) ? "-0.0" : "0.0"
    s = string(abs(x))                                   # Julia's shortest round-trip digits
    m, e = occursin('e', s) ? (split(s, 'e')[1], parse(Int, split(s, 'e')[2])) : (s, 0)
    ip, fp = split(m, '.')
    digits = ip * fp
    point = length(ip) + e                               # digits before the decimal point
    nz = findfirst(!=('0'), digits)
    point -= nz - 1
    digits = rstrip(digits[nz:end], '0')
    exp10 = point - 1
    sgn = x < 0 ? "-" : ""
    if -4 <= exp10 < 16
        body = point <= 0 ? "0." * "0"^(-point) * digits :
               point >= length(digits) ? digits * "0"^(point - length(digits)) * ".0" :
               digits[1:point] * "." * digits[point+1:end]
        return sgn * body
    end
    mant = length(digits) == 1 ? digits : digits[1:1] * "." * digits[2:end]
    return sgn * mant * "e" * (exp10 < 0 ? "-" : "+") * lpad(abs(exp10), 2, '0')
end

const NUMBER_RE = r"^([-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?|[+-]?[0-9]+\.)$"
# As in the Python client; only its first and last alternatives are anchored.
const DONT_CARE_RE = r"^-2147483648.0|\(\)|N/A|NOT APPLICABLE|NOT_APPLICABLE$"

"""
    condition_value(value) -> String

A header or rule value in the form rules are matched in (the Python client's
`utils.condition_value`): upper case, numbers as Python floats, `N/A`-like values as `"N/A"`,
`ANY` as `"*"`, booleans as `"T"`/`"F"`.
"""
function condition_value(value)
    v = uppercase(strip(_pystr(value)))
    occursin(NUMBER_RE, v) && (v = pyfloatstr(parse(Float64, v)))
    occursin(DONT_CARE_RE, v) && (v = "N/A")
    v == "ANY" && return "*"
    v == "4294967295.0" && return "-1.0"
    v in ("T", "TRUE") && return "T"
    v in ("F", "FALSE") && return "F"
    return v
end

esoteric_key(key) = (k = uppercase(key);
    (startswith(k, ('{', '(', '#')) && endswith(k, ('}', ')', '#'))) || startswith(k, "BETWEEN") || startswith(k, "NOT"))
glob_list(value) = !esoteric_key(value) && occursin('|', value) ? sort([strip(v) for v in split(value, '|') if !isempty(strip(v))]) : [value]
glob_compress(value) = join(glob_list(value), "|")

function condition_key_element(elem)
    if elem isa AbstractString
        # raw regexes (...) and literal equalities {...} are not conditioned
        if (startswith(elem, '{') && endswith(elem, '}')) || (startswith(elem, '(') && endswith(elem, ')'))
            return String(elem)
        end
        occursin('|', elem) && return join(condition_value.(glob_list(elem)), "|")
        return condition_value(glob_compress(elem))
    elseif elem isa Union{Tuple, AbstractVector}
        return join(condition_value.(collect(elem)), "|")
    end
    return condition_value(elem)
end
condition_key(key) = key isa Tuple ? map(condition_key_element, key) : (condition_key_element(key),)

"""
    reformat_date(date) -> String

`date` in CRDS's standard form `YYYY-MM-DD HH:MM:SS[.ffffff]` (Python `isoformat(" ")`), from
`YYYY-MM-DD`, `YYYY-MM-DD HH:MM[:SS[.f]]`, the same with `T` or `/`, or a `Dates.DateTime`.
"""
reformat_date(date::Dates.DateTime) = reformat_date(Dates.format(date, "yyyy-mm-dd HH:MM:SS.sss"))
function reformat_date(date)
    s = strip(_pystr(date))
    endswith(s, " UT") && (s = s[1:end-3])
    occursin("UNDEFINED", s) && throw(ValidationFailure("One or more required date/time values is UNDEFINED"))
    m = match(r"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T]+(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?$", s)
    m === nothing && throw(ArgumentError("unrecognized date/time $(repr(s))"))
    n(i, d = 0) = m.captures[i] === nothing ? d : parse(Int, m.captures[i])
    dt = Dates.DateTime(n(1), n(2), n(3), n(4), n(5), n(6))     # throws on an impossible date
    us = m.captures[7] === nothing ? 0 : parse(Int, rpad(first(m.captures[7], 6), 6, '0'))
    return Dates.format(dt, "yyyy-mm-dd HH:MM:SS") * (us == 0 ? "" : "." * lpad(us, 6, '0'))
end

# --- matchers: 1 = match, 0 = don't care, -1 = no match ---------------------------------------

abstract type Matcher end
_base(key, v) = v == key || v == "*" ? 1 : v == "N/A" ? 0 : -1

struct EqMatcher <: Matcher
    key::String
end
match_value(m::EqMatcher, v) = _base(m.key, v)

struct RegexMatcher <: Matcher          # Python re.match: anchored at the start only
    key::String
    re::Regex
end
RegexMatcher(key) = RegexMatcher(key, Regex("^(?:" * key * ")"))
match_value(m::RegexMatcher, v) = (r = _base(m.key, v); r != -1 ? r : occursin(m.re, v) ? 1 : -1)

# fnmatch.translate: * any run, ? one character, [seq] / [!seq] classes, the rest literal.
function _glob_regex(pat)
    io = IOBuffer(); cs = collect(pat); i = 1
    while i <= length(cs)
        c = cs[i]
        if c == '*'
            write(io, ".*")
        elseif c == '?'
            write(io, ".")
        elseif c == '['
            # as fnmatch: a leading '!' negates, a ']' right after '[' or '[!' is literal
            j = i + 1
            j <= length(cs) && cs[j] == '!' && (j += 1)
            j <= length(cs) && cs[j] == ']' && (j += 1)
            j = findnext(==(']'), cs, j)
            if j === nothing
                write(io, "\\[")
            else
                body = replace(String(cs[i+1:j-1]), "\\" => "\\\\")
                write(io, "[", startswith(body, '!') ? "^" * body[2:end] : body, "]")
                i = j
            end
        else
            write(io, isletter(c) || isdigit(c) || c == '_' ? string(c) : "\\" * c)
        end
        i += 1
    end
    return "(?s:" * String(take!(io)) * ")\\z"
end
GlobMatcher(key) = RegexMatcher("^(" * join(_glob_regex.(glob_list(key)), "|") * ")\$")

struct InequalityMatcher <: Matcher
    key::String
    op::String
    value::Float64
end
function InequalityMatcher(key::AbstractString)
    m = match(r"^([><]=?)\s*([-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?)", key)
    m === nothing && throw(CRDSError("bad inequality $(repr(key))"))
    return InequalityMatcher(key, m.captures[1], parse(Float64, m.captures[2]))
end
function match_value(m::InequalityMatcher, v)
    r = _base(m.key, v); r != -1 && return r
    x = tryparse(Float64, v); x === nothing && return -1
    ok = m.op == ">" ? x > m.value : m.op == "<" ? x < m.value : m.op == ">=" ? x >= m.value : x <= m.value
    return ok ? 1 : -1
end

struct BinaryMatcher <: Matcher
    key::String
    op::String
    a::Matcher
    b::Matcher
end
function BinaryMatcher(key::AbstractString, op::AbstractString)
    k = strip(key)
    startswith(k, '#') && (k = k[2:end-1])
    parts = strip.(split(k, op))
    return BinaryMatcher(key, op, matcher(parts[1]), matcher(parts[2]))
end
function match_value(m::BinaryMatcher, v)
    v = uppercase(v)
    r = _base(m.key, v); r != -1 && return r
    a, b = match_value(m.a, v) == 1, match_value(m.b, v) == 1
    return (m.op == "AND" ? a && b : a || b) ? 1 : -1
end

struct NaMatcher <: Matcher end
match_value(::NaMatcher, v) = 0

struct NotMatcher <: Matcher
    inner::Matcher
end
match_value(m::NotMatcher, v) = -match_value(m.inner, v)

"The matcher for one rule key element (the Python client's `selectors.matcher`)."
function matcher(key)
    key isa Tuple && return GlobMatcher(join(key, "|"))
    if startswith(key, '(') && endswith(key, ')')
        return RegexMatcher(key[2:end-1])
    elseif startswith(key, '{') && endswith(key, '}')
        return EqMatcher(key[2:end-1])
    elseif startswith(key, '#') && endswith(key, '#')
        k = uppercase(key)
        occursin(" AND ", k) && return BinaryMatcher(k, "AND")
        occursin(" OR ", k) && return BinaryMatcher(k, "OR")
        return matcher(k[2:end-1])
    elseif startswith(uppercase(key), "BETWEEN")
        p = split(key)
        (length(p) == 3 && parse(Float64, p[2]) <= parse(Float64, p[3])) || throw(CRDSError("invalid between relation $(repr(key))"))
        return BinaryMatcher(">=" * p[2] * " AND <" * p[3], "AND")
    elseif startswith(uppercase(key), "NOT ")
        return NotMatcher(matcher(strip(key[5:end])))
    elseif occursin('|', key) || occursin('*', key)
        return GlobMatcher(key)
    elseif key == "N/A"
        return NaMatcher()
    elseif startswith(key, ('>', '<'))
        return InequalityMatcher(key)
    end
    return EqMatcher(key)
end

# --- selectors --------------------------------------------------------------------------------

abstract type Selector end

const DEFAULT_SUBSTITUTIONS = Dict{String, Dict{String, Any}}("META.SUBARRAY.NAME" => Dict("GENERIC" => "N/A"),
                                                              "SUBARRAY" => Dict("GENERIC" => "N/A"))

struct MatchEntry
    key::Tuple                  # conditioned key, one element per parameter
    matchers::Vector{Matcher}
    choice::Any                 # file name, N/A, or a nested Selector
end

struct MatchSelector <: Selector
    parameters::Vector{String}
    entries::Vector{MatchEntry}
    valid::Vector{Union{Nothing, Vector{String}}}   # per parameter, values the rules list (nothing: unchecked)
    substitutions::Dict{String, Dict{String, Any}}
    merge_overlaps::Bool
end

struct UseAfterSelector <: Selector
    parameters::Vector{String}
    keys::Vector{String}        # sorted dates
    choices::Vector{Any}
end

# UseAfter on software versions (the Python client's VersionAfterSelector): versions reduce to
# (major, minor, point), e.g. "0.13.2a.dev185+gdb49aea9" -> (0, 13, 2), "0.7" -> (0, 7, 0); the
# greatest rule version <= the header's wins.
struct VersionAfterSelector <: Selector
    parameters::Vector{String}
    keys::Vector{NTuple{3, Int}}      # sorted
    choices::Vector{Any}
end

const VERSION_RE = r"^(\d{1,8}(\.\d{1,8}(\.\d{1,8})?)?)[a-zA-Z0-9_\+\-\.]{0,128}$"

function version_key(v)
    m = match(VERSION_RE, v)
    m === nothing && throw(ValidationFailure("Invalid version string $(_pyrepr(v))"))
    p = parse.(Int, split(m.captures[1], '.'))
    return (p[1], get(p, 2, 0), get(p, 3, 0))
end

struct UnsupportedSelector <: Selector
    name::String
end

"A selector tree from a mapping's `selector` expression; parameter level `depth` of `parkey`."
function build_selector(x, parkey, header; depth = 1)
    x isa AbstractString && return String(x)
    x isa Call || return UnsupportedSelector("choice of type $(typeof(x))")
    params = depth <= length(parkey) ? String[string(p) for p in parkey[depth]] : String[]
    if x.name == "Match"
        return MatchSelector(params, only(x.args), parkey, header, depth)
    elseif x.name == "UseAfter"
        d = only(x.args)
        ks = sort!([string(k) for k in keys(d)])
        return UseAfterSelector(params, ks, Any[build_selector(d[k], parkey, header; depth = depth + 1) for k in ks])
    elseif x.name == "VersionAfter"
        d = only(x.args)
        raw = sort!([string(k) for k in keys(d)]; by = version_key)
        return VersionAfterSelector(params, version_key.(raw), Any[build_selector(d[k], parkey, header; depth = depth + 1) for k in raw])
    end
    return UnsupportedSelector(x.name)
end

function MatchSelector(params, raw::AbstractDict, parkey, header, depth)
    subs = merge(DEFAULT_SUBSTITUTIONS, Dict{String, Dict{String, Any}}(string(k) => Dict{String, Any}(string(a) => b for (a, b) in v)
                                                                     for (k, v) in get(header, "substitutions", Dict())))
    sel = Dict{Any, Any}(raw)
    for (i, p) in enumerate(params)           # rule-value substitutions (header "substitutions")
        haskey(subs, p) || continue
        for k in collect(keys(sel))
            old = k isa Tuple ? k[i] : k
            (old isa AbstractString && haskey(subs[p], old)) || continue
            new = subs[p][old]; new isa AbstractVector && (new = Tuple(new))
            nk = k isa Tuple ? Tuple(j == i ? new : k[j] for j in eachindex(k)) : new
            sel[nk] = pop!(sel, k)
        end
    end
    entries = MatchEntry[]
    for (k, v) in sel
        ck = condition_key(k)
        length(ck) == length(params) || throw(CRDSError("match key $(repr(k)) has $(length(ck)) values for parameters $params"))
        push!(entries, MatchEntry(ck, Matcher[matcher(e) for e in ck], build_selector(v, parkey, header; depth = depth + 1)))
    end
    sort!(entries; by = e -> e.key)
    for i in 2:length(entries)
        entries[i].key == entries[i-1].key && throw(CRDSError("duplicate match key $(entries[i].key)"))
    end
    valid = Union{Nothing, Vector{String}}[any(esoteric_key(e.key[i]) for e in entries) ? nothing :
                                           sort!(unique!(String[v for e in entries for v in glob_list(e.key[i])])) for i in eachindex(params)]
    mo = uppercase(string(get(header, "merge_overlaps", "TRUE"))) in ("TRUE", "1")
    return MatchSelector(params, entries, valid, subs, mo)
end

# The Python client's Selector._validate_value at lookup time.
function _check_value(sel::MatchSelector, i, value)
    valid = sel.valid[i]
    (valid === nothing || isempty(valid) || value in valid || condition_value(value) in valid) && return
    any(in(valid), ("*", "ANY", "N/A")) && return
    (esoteric_key(value) || value in ("*", "ANY", "N/A")) && return
    name = sel.parameters[i]
    haskey(sel.substitutions, name) && haskey(sel.substitutions[name], value) && return
    throw(ValidationFailure("parameter=$(_pyrepr(name)) value=$(_pyrepr(value)) is not in [" * join(_pyrepr.(valid), ", ") * "]"))
end

"""
    choose(selector, header) -> String

The choice (file name or N/A) `selector` makes for the conditioned `header`.  Throws
`LookupFailure` (no match), `ValidationFailure` (header rejected) or `UnsupportedRule`.
"""
choose(x::String, header) = x
choose(s::UnsupportedSelector, header) = throw(UnsupportedRule("selector $(s.name)"))

function choose(sel::MatchSelector, header)
    vals = [get(header, p, "UNDEFINED") for p in sel.parameters]
    for i in eachindex(vals)
        _check_value(sel, i, vals[i])
    end
    # winnow: drop clauses that cannot match; weight = -(number of exact matches), lower is better
    weights = Dict{Int, Int}()
    for (j, e) in enumerate(sel.entries)
        w = 0
        for i in eachindex(vals)
            s = match_value(e.matchers[i], vals[i])
            s == -1 && (w = typemax(Int); break)
            w -= s
        end
        w == typemax(Int) || (weights[j] = w)
    end
    last_failure = nothing
    for w in sort!(unique(values(weights)))
        group = sort!([j for (j, v) in weights if v == w])
        choice = if length(group) == 1
            sel.entries[group[1]].choice
        else
            sel.merge_overlaps || throw(ValidationFailure("More than one match clause matched: $([sel.entries[j].key for j in group])"))
            cs = [sel.entries[j].choice for j in group]
            (all(c -> c isa UseAfterSelector, cs) || all(c -> c isa VersionAfterSelector, cs)) ||
                throw(cs[1] isa Selector ? UnsupportedRule("merging $(typeof(cs[1]))") :
                      ValidationFailure("More than one match clause matched: $([sel.entries[j].key for j in group])"))
            reduce(merge_after, cs)
        end
        try
            return choose(choice, header)
        catch e
            e isa LookupFailure || rethrow()
            last_failure = e
        end
    end
    throw(LookupFailure("No match found." * (last_failure === nothing ? "" : " ($(last_failure.msg))")))
end

function choose(sel::UseAfterSelector, header)
    parts = String[]
    for p in sel.parameters
        v = strip(get(header, p, "UNDEFINED"))
        v == "UNDEFINED" && throw(ValidationFailure("UseAfter parameter $(_pyrepr(p)) is UNDEFINED."))
        push!(parts, v)
    end
    raw = join(parts, " ")
    date = try
        reformat_date(raw)
    catch e
        throw(ValidationFailure("UseAfter Invalid date/time format for $(Tuple(sel.parameters)) value = $(_pyrepr(raw)) exception is $(sprint(showerror, e))"))
    end
    k = searchsortedlast(sel.keys, date)
    k == 0 && throw(LookupFailure("No selection <= $(_pyrepr(date))"))
    return choose(sel.choices[k], header)
end

function choose(sel::VersionAfterSelector, header)
    raw = glob_compress(join((get(header, p, "UNDEFINED") for p in sel.parameters), "."))
    v = version_key(raw)
    k = searchsortedlast(sel.keys, v)
    k == 0 && throw(LookupFailure("No selection <= $(_pyrepr(raw))"))
    return choose(sel.choices[k], header)
end

# Two UseAfter (or VersionAfter) selectors as one; on equal keys the greater choice (file name)
# wins, as in the Python client.
merge_after(a::UseAfterSelector, b::UseAfterSelector) = UseAfterSelector(a.parameters, _merge_sorted(a.keys, a.choices, b.keys, b.choices)...)
merge_after(a::VersionAfterSelector, b::VersionAfterSelector) = VersionAfterSelector(a.parameters, _merge_sorted(a.keys, a.choices, b.keys, b.choices)...)

function _merge_sorted(akeys, achoices, bkeys, bchoices)
    a = (; keys = akeys, choices = achoices); b = (; keys = bkeys, choices = bchoices)
    ks = similar(akeys, 0); cs = Any[]
    i = j = 1
    while i <= length(a.keys) && j <= length(b.keys)
        if a.keys[i] < b.keys[j]
            push!(ks, a.keys[i]); push!(cs, a.choices[i]); i += 1
        elseif b.keys[j] < a.keys[i]
            push!(ks, b.keys[j]); push!(cs, b.choices[j]); j += 1
        else
            ca, cb = a.choices[i], b.choices[j]
            push!(ks, a.keys[i]); push!(cs, string(ca) >= string(cb) ? ca : cb); i += 1; j += 1
        end
    end
    append!(ks, a.keys[i:end]); append!(cs, a.choices[i:end])
    append!(ks, b.keys[j:end]); append!(cs, b.choices[j:end])
    return ks, cs
end

"File names a selector can choose (N/A and other special values excluded)."
reference_names(x::String) = x in NA_VALUES || x in OMIT_VALUES ? String[] : [x]
reference_names(::UnsupportedSelector) = String[]
reference_names(s::MatchSelector) = unique!(reduce(vcat, (reference_names(e.choice) for e in s.entries); init = String[]))
reference_names(s::Union{UseAfterSelector, VersionAfterSelector}) = unique!(reduce(vcat, (reference_names(c) for c in s.choices); init = String[]))
