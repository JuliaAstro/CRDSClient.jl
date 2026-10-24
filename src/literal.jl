# CRDS mapping files (.pmap/.imap/.rmap) and the Python client's stored server_config are Python
# source: assignments of literals, plus selector calls such as `Match({...})`.  This is a
# recursive-descent parser for exactly that subset, with no evaluation:
#   strings ('...', "...", triple-quoted, adjacent ones concatenated), ints, floats, True, False,
#   None, tuples, lists, dicts and `Name(args...)` calls, and `#` comments.
# Tuples become Julia `Tuple`s, lists `Vector{Any}`, dicts `Dict{Any, Any}` (duplicate keys are
# an error, as in the Python client) and calls `Call`s.

"A `Name(args...)` call in a mapping file, e.g. `Match({...})`."
struct Call
    name::String
    args::Vector{Any}
end
Base.:(==)(a::Call, b::Call) = a.name == b.name && a.args == b.args

mutable struct LiteralParser
    s::String
    i::Int
    source::String
end

function _error(p::LiteralParser, msg)
    line = count(==('\n'), SubString(p.s, 1, prevind(p.s, min(p.i, ncodeunits(p.s) + 1)))) + 1
    throw(CRDSError("cannot parse $(p.source), line $line: $msg"))
end

_peek(p::LiteralParser) = p.i <= ncodeunits(p.s) ? p.s[p.i] : '\0'
_advance!(p::LiteralParser) = (p.i = nextind(p.s, p.i))

function _skip!(p::LiteralParser)
    while p.i <= ncodeunits(p.s)
        c = p.s[p.i]
        if isspace(c)
            _advance!(p)
        elseif c == '#'
            while p.i <= ncodeunits(p.s) && p.s[p.i] != '\n'
                _advance!(p)
            end
        else
            break
        end
    end
end

function _expect!(p::LiteralParser, c::Char)
    _skip!(p)
    _peek(p) == c || _error(p, "expected '$c', found '$(_peek(p))'")
    _advance!(p)
end

function _string!(p::LiteralParser)
    q = _peek(p)
    triple = startswith(SubString(p.s, p.i), string(q)^3)
    p.i += triple ? 3 : 1
    io = IOBuffer()
    while true
        p.i > ncodeunits(p.s) && _error(p, "unterminated string")
        c = p.s[p.i]
        if c == '\\'
            _advance!(p)
            e = _peek(p)
            write(io, get(Dict('n' => '\n', 't' => '\t', 'r' => '\r', '0' => '\0'), e, e))
            _advance!(p)
        elseif triple ? startswith(SubString(p.s, p.i), string(q)^3) : c == q
            p.i += triple ? 3 : 1
            break
        else
            !triple && c == '\n' && _error(p, "newline in string")
            write(io, c)
            _advance!(p)
        end
    end
    return String(take!(io))
end

function _number!(p::LiteralParser)
    m = match(r"[-+]?(\d+\.?\d*([eE][-+]?\d+)?|\.\d+([eE][-+]?\d+)?)", p.s, p.i)
    (m === nothing || m.offset != p.i) && _error(p, "bad number")
    p.i += ncodeunits(m.match)
    t = m.match
    return occursin(r"[.eE]", t) ? parse(Float64, t) : parse(Int, t)
end

# Comma-separated items up to `close`; returns the items and whether any comma was seen.
function _items!(p::LiteralParser, close::Char, item)
    items = Any[]; comma = false
    while true
        _skip!(p)
        _peek(p) == close && (_advance!(p); return items, comma)
        push!(items, item())
        _skip!(p)
        if _peek(p) == ','
            _advance!(p); comma = true
        elseif _peek(p) != close
            _error(p, "expected ',' or '$close', found '$(_peek(p))'")
        end
    end
end

function _expr!(p::LiteralParser)
    _skip!(p)
    c = _peek(p)
    if c == '\'' || c == '"'
        s = _string!(p)
        while (_skip!(p); _peek(p) in ('\'', '"'))   # adjacent literals concatenate
            s *= _string!(p)
        end
        return s
    elseif c == '{'
        _advance!(p)
        d = Dict{Any, Any}()
        pairs, _ = _items!(p, '}', () -> (k = _expr!(p); _expect!(p, ':'); k => _expr!(p)))
        for (k, v) in pairs
            haskey(d, k) && _error(p, "duplicate key $(repr(k))")
            d[k] = v
        end
        return d
    elseif c == '('
        _advance!(p)
        items, comma = _items!(p, ')', () -> _expr!(p))
        return length(items) == 1 && !comma ? items[1] : Tuple(items)
    elseif c == '['
        _advance!(p)
        return _items!(p, ']', () -> _expr!(p))[1]
    elseif isdigit(c) || c in ('-', '+', '.')
        return _number!(p)
    elseif isletter(c) || c == '_'
        name = match(r"[A-Za-z_][A-Za-z_0-9]*", p.s, p.i).match
        p.i += ncodeunits(name)
        name == "True" && return true
        name == "False" && return false
        name == "None" && return nothing
        _skip!(p)
        _peek(p) == '(' || _error(p, "unknown name $name")
        _advance!(p)
        return Call(name, _items!(p, ')', () -> _expr!(p))[1])
    end
    _error(p, "unexpected '$c'")
end

"""
    parse_literal(text; source = "string")

The value of one Python literal expression in `text` (see the file comment for the subset).
"""
function parse_literal(text::AbstractString; source = "string")
    p = LiteralParser(String(text), 1, source)
    v = _expr!(p)
    _skip!(p)
    p.i > ncodeunits(p.s) || _error(p, "trailing text")
    return v
end

"""
    parse_assignments(text; source = "string") -> Dict{String, Any}

The `name = literal` assignments of a Python source file such as a CRDS mapping, e.g.
`"header"` and `"selector"`.
"""
function parse_assignments(text::AbstractString; source = "string")
    p = LiteralParser(String(text), 1, source)
    out = Dict{String, Any}()
    while (_skip!(p); p.i <= ncodeunits(p.s))
        m = match(r"[A-Za-z_][A-Za-z_0-9]*", p.s, p.i)
        (m === nothing || m.offset != p.i) && _error(p, "expected an assignment")
        p.i += ncodeunits(m.match)
        _expect!(p, '=')
        out[m.match] = _expr!(p)
    end
    return out
end
