# Base's verbs for an EcmaRegex (occursin, match, eachmatch, findfirst, findnext, findall, count, replace and split),
# ECMA-262's split, Utf8Text (UTF-8 checked once) and Captures (the groups of a match, kept from one match to the next so
# that matching allocates nothing). Indices here are Julia's: 1-based, in code units of the text (bytes of a string, or
# UTF-16 code units of a vector of them).

"""
    Utf8Text(s)

UTF-8 text that has been checked once, so that the methods that take it check nothing. A program that matches one text
many times makes a Utf8Text of it and pays for the check once. Utf8Text that is not UTF-8 throws an EncodingError.
"""
struct Utf8Text
    s::String
    function Utf8Text(s::AbstractString)
        s = String(s)
        isvalid(s) || throw(NOT_UTF8)
        return new(s)
    end
end

Utf8Text(b::Bytes) = Utf8Text(String(copy(b)))

Base.String(t::Utf8Text) = t.s
Base.length(t::Utf8Text) = ncodeunits(t.s)

# The UTF-8 subjects: the text of each, its units, and whether it has been checked. A string is checked on each call.
const Subject8 = Union{String,SubString{String}}

utf8_string(s::Subject8) = s
utf8_string(s::AbstractString) = String(s)
utf8_string(t::Utf8Text) = t.s

function checked_units(s::AbstractString)
    s = utf8_string(s)
    isvalid(s) || throw(NOT_UTF8)
    return codeunits(s)
end
checked_units(t::Utf8Text) = codeunits(t.s)
checked_units(u::Units) = u
function checked_units(b::Bytes)
    isvalid(String, b) || throw(NOT_UTF8)
    return b
end

# What a match of a subject reports its pieces as: a SubString of a string, a view of a vector of UTF-16 code units.
piece(s::AbstractString, from::Int, to::Int) = piece8(utf8_string(s), from, to)
piece(t::Utf8Text, from::Int, to::Int) = piece8(t.s, from, to)
piece(u::Units, from::Int, to::Int) = view(u, from+1:to)
piece(b::Bytes, from::Int, to::Int) = view(b, from+1:to)

"""
s[from:to) as a SubString, or one of a copy with U+FFFD for a half character at a bound between the halves of a
character of four bytes, which only a pattern without the u flag can make.
"""
function piece8(s::Subject8, from::Int, to::Int)
    b = codeunits(s)
    if inside_four(b, from) || to < length(b) && inside_four(b, to)
        out = String(push_lossy!(UInt8[], b, from, to))
        return SubString(out)
    end
    return SubString(s, from + 1, prevind(s, to + 1))
end

piece_type(::AbstractString) = SubString{String}
piece_type(::Utf8Text) = SubString{String}
piece_type(u::Units) = typeof(view(u, 1:0))
piece_type(b::Bytes) = typeof(view(b, 1:0))

"""
    EcmaMatch

A match of an EcmaRegex, read as a RegexMatch is: `m.match`, `m.captures` (`nothing` for a group that did not take
part), `m.offset` and `m.offsets` (0 for a group that did not take part), 1-based in code units; `m[1]`, `m[:name]` and
`m["name"]`.
"""
struct EcmaMatch{S} <: AbstractMatch
    match::S
    captures::Vector{Union{Nothing,S}}
    offset::Int
    offsets::Vector{Int}
    regex::EcmaRegex
end

function EcmaMatch(re::EcmaRegex, subject, slots::Vector{Int})
    S = piece_type(subject)
    caps = Union{Nothing,S}[]
    offsets = Int[]
    for g in 1:re.groups
        from, to = slots[2g+1], slots[2g+2]
        if from == NONE
            push!(caps, nothing)
            push!(offsets, 0)
        else
            push!(caps, piece(subject, from, to))
            push!(offsets, from + 1)
        end
    end
    return EcmaMatch{S}(piece(subject, slots[1], slots[2]), caps, slots[1] + 1, offsets, re)
end

Base.getindex(m::EcmaMatch, i::Integer) = m.captures[i]

function Base.getindex(m::EcmaMatch, name::Union{AbstractString,Symbol})
    groups = group_index(m.regex, string(name))
    isempty(groups) && throw(ArgumentError("no group named $(name)"))
    for g in groups
        m.captures[g] === nothing || return m.captures[g]
    end
    return nothing
end

function Base.haskey(m::EcmaMatch, name::Union{AbstractString,Symbol})
    !isempty(group_index(m.regex, string(name)))
end

function Base.keys(m::EcmaMatch)
    names = group_names(m.regex)
    return Any[n === nothing ? k : n for (k, n) in enumerate(names)]
end

Base.show(io::IO, m::EcmaMatch) = print(io, "EcmaMatch(", repr(m.match), ")")

"The 0-based position a search from a 1-based index starts at."
start_of(i::Integer) = Int(i) - 1

"""
    occursin(re::EcmaRegex, s)

Whether the pattern matches the text: a string (checked to be UTF-8), a Utf8Text, or a vector of UTF-16 code units. With the
y flag the match must start at the start.
"""
function occursin_impl(re::EcmaRegex, s::Union{AbstractString,Utf8Text,Units,Bytes})
    return test(re, checked_units(s), 0)
end

"""
    match(re::EcmaRegex, s, i = 1)

The first match at or after index `i` (at `i` alone with the y flag), or `nothing`.
"""
function match_impl(re::EcmaRegex, s::Union{AbstractString,Utf8Text,Units,Bytes}, i::Integer)
    units = checked_units(s)
    slots = Vector{Int}(undef, 2 * (re.groups + 1))
    exec_slots(re, units, start_of(i), re.flags.sticky, slots)[3] || return nothing
    return EcmaMatch(re, s, slots)
end

"""
    findnext(re::EcmaRegex, s, i)

The code units of the first match at or after index `i`, as a range, or `nothing`.
"""
function findnext_impl(re::EcmaRegex, s::Union{AbstractString,Utf8Text,Units,Bytes}, i::Integer)
    from, to, found = exec_slots(re, checked_units(s), start_of(i), re.flags.sticky, nothing)
    return found ? (from+1:to) : nothing
end


"""
The matches of a global search of the text, as String.prototype.matchAll makes them: after an empty match the search
moves on one character (a code point with the u or v flag, a code unit without).
"""
struct EcmaMatches{T}
    re::EcmaRegex
    subject::T
end

"""
    eachmatch(re::EcmaRegex, s)

The matches of a global search of the text, each an EcmaMatch, as String.prototype.matchAll gives them.
"""
eachmatch_impl(re::EcmaRegex, s::Union{AbstractString,Utf8Text,Units,Bytes}) = EcmaMatches(re, (checked_units(s); s))

Base.IteratorSize(::Type{<:EcmaMatches}) = Base.SizeUnknown()
Base.eltype(::Type{EcmaMatches{T}}) where {T} = EcmaMatch{piece_type_of(T)}
piece_type_of(::Type{<:Union{AbstractString,Utf8Text}}) = SubString{String}
piece_type_of(::Type{T}) where {T<:Union{Units,Bytes}} = Base.promote_op(view, T, UnitRange{Int})

function Base.iterate(m::EcmaMatches, at::Int=0)
    units = subject_units(m.subject)
    at > length(units) && return nothing
    slots = Vector{Int}(undef, 2 * (m.re.groups + 1))
    from, to, found = exec_slots(m.re, units, at, m.re.flags.sticky, slots)
    found || return nothing
    return EcmaMatch(m.re, m.subject, slots), next_start(m.re, units, from, to)
end

# Each verb has a method for each kind of subject, which Base's own methods (on a union of patterns and strings) would
# otherwise make ambiguous.
for T in (:AbstractString, :Utf8Text, :Units, :Bytes)
    @eval begin
        Base.occursin(re::EcmaRegex, s::$T) = occursin_impl(re, s)
        Base.match(re::EcmaRegex, s::$T, i::Integer=1) = match_impl(re, s, i)
        Base.findnext(re::EcmaRegex, s::$T, i::Integer) = findnext_impl(re, s, i)
        Base.findfirst(re::EcmaRegex, s::$T) = findnext_impl(re, s, 1)
        Base.eachmatch(re::EcmaRegex, s::$T) = eachmatch_impl(re, s)
        Base.findall(re::EcmaRegex, s::$T) = findall_impl(re, s)
        Base.count(re::EcmaRegex, s::$T) = count_impl(re, s)
    end
end

subject_units(s::AbstractString) = codeunits(utf8_string(s))
subject_units(t::Utf8Text) = codeunits(t.s)
subject_units(u::Units) = u
subject_units(b::Bytes) = b

"""
    findall(re::EcmaRegex, s)

The code units of each match of a global search, as ranges.
"""
function findall_impl(re::EcmaRegex, s::Union{AbstractString,Utf8Text,Units,Bytes})
    return [b[1]+1:b[2] for b in find_all(re, checked_units(s), -1, false)]
end

"""
    count(re::EcmaRegex, s)

The number of matches of a global search of the text.
"""
function count_impl(re::EcmaRegex, s::Union{AbstractString,Utf8Text,Units,Bytes})
    units = checked_units(s)
    n, at = 0, 0
    while at <= length(units)
        from, to, found = exec_slots(re, units, at, re.flags.sticky, nothing)
        found || break
        n += 1
        at = next_start(re, units, from, to)
    end
    return n
end

"""
    replace(s, re::EcmaRegex => template; count)

The text with every match (at most `count`) replaced by the template, with its \$ forms (\$\$, \$&, \$`, \$', \$n, \$nn
and \$<name>) replaced as String.prototype.replace replaces them. Over a vector of UTF-16 code units the template is one
too.
"""
Base.replace(s::AbstractString, pat::Pair{EcmaRegex,<:AbstractString}; count::Integer=typemax(Int)) =
    replace_template(s, pat; count)
Base.replace(s::Utf8Text, pat::Pair{EcmaRegex,<:AbstractString}; count::Integer=typemax(Int)) =
    replace_template(s, pat; count)

function replace_template(s::Union{AbstractString,Utf8Text}, pat::Pair{EcmaRegex,<:AbstractString}; count::Integer)
    re, template = pat
    input = checked_units(s)
    out = replace_units(re, input, checked_units(template), true; count=Int(count))
    return out === nothing ? String(utf8_string(s)) : String(out)
end

function Base.replace(u::Units, pat::Pair{EcmaRegex,<:Units}; count::Integer=typemax(Int))
    re, template = pat
    out = replace_units(re, u, template, true; count=Int(count))
    return out === nothing ? Vector{UInt16}(u) : out
end

function Base.replace(b::Bytes, pat::Pair{EcmaRegex,<:Bytes}; count::Integer=typemax(Int))
    re, template = pat
    out = replace_units(re, checked_units(b), checked_units(template), true; count=Int(count))
    return out === nothing ? Vector{UInt8}(b) : out
end

"""
    split(s, re::EcmaRegex; limit = 0, keepempty = true)

The pieces of the text between the matches, as `split` with a Regex gives them: at most `limit` pieces when it is more
than 0, the empty ones dropped when `keepempty` is false. The groups of the matches are not among them; `ecmasplit`
gives String.prototype.split's answer, which has them.
"""
Base.split(s::T, re::EcmaRegex; limit::Integer=0, keepempty::Bool=true) where {T<:AbstractString} =
    split_impl(s, re, limit, keepempty)
Base.split(s::Utf8Text, re::EcmaRegex; limit::Integer=0, keepempty::Bool=true) = split_impl(s, re, limit, keepempty)

function split_impl(s::Union{AbstractString,Utf8Text}, re::EcmaRegex, limit::Integer, keepempty::Bool)
    # Base's split with a Regex, over positions from 0: i is where the next piece starts, j and k where the match
    # starts and ends.
    input = checked_units(s)
    n = length(input)
    pieces = SubString{String}[]
    i = 0
    from, to, found = exec_slots(re, input, 0, false, nothing)
    if found
        j, k = from, to
        while 0 <= j < n && length(pieces) != limit - 1
            if i < k
                (keepempty || i < j) && push!(pieces, piece(s, i, j))
                i = k
            end
            k <= j && (k = advance(input, j, is_unicode(re)))
            from, to, found = exec_slots(re, input, k, false, nothing)
            found || break
            j, k = from, to
        end
    end
    push!(pieces, piece(s, i, n))
    return pieces
end

"""
    ecmasplit(s, re::EcmaRegex; limit = -1)

The text split around the matches as String.prototype.split splits it: the pieces, with the groups of each match
between them (`nothing` for a group that did not take part), at most `limit` items (all when it is below 0).
"""
function ecmasplit(s::Union{AbstractString,Utf8Text,Units,Bytes}, re::EcmaRegex; limit::Integer=-1)
    S = piece_type(s)
    out = Union{Nothing,S}[]
    for (from, to) in split_units(re, checked_units(s), Int(limit))
        push!(out, from == NONE ? nothing : piece(s, from, to))
    end
    return out
end

"""
    Captures(re)

The start and end of a match and of each group of a pattern. A match into one with `match!` allocates nothing once the
working memory has grown, so a program that matches many times makes one and passes it to each match. A Captures is not
safe to share between tasks.
"""
mutable struct Captures
    re::EcmaRegex
    slots::Vector{Int}
    found::Bool
end

Captures(re::EcmaRegex) = Captures(re, Vector{Int}(undef, 2 * (re.groups + 1)), false)

"""
    match!(c::Captures, s, i = 1)

Finds the first match at or after index `i` of the text into the Captures, and reports whether there was one. It
allocates nothing once the working memory has grown.
"""
function match!(c::Captures, s::Union{AbstractString,Utf8Text,Units,Bytes}, i::Integer=1)
    c.found = exec_slots(c.re, checked_units(s), start_of(i), c.re.flags.sticky, c.slots)[3]
    return c.found
end

"Whether the last match into the Captures found one."
found(c::Captures) = c.found

"""
    capture_range(c::Captures, g = 0)

The code units of group `g` of the last match (0 for the whole match), as a range, or `nothing` for a group that did not
take part.
"""
function capture_range(c::Captures, g::Integer=0)
    c.found || return nothing
    from, to = c.slots[2g+1], c.slots[2g+2]
    return from == NONE ? nothing : (from+1:to)
end

"The matches of a global search into one Captures (see eachmatch!)."
struct CapturesMatches{T}
    c::Captures
    subject::T
end

"""
    eachmatch!(c::Captures, s)

The matches of a global search of the text, as String.prototype.matchAll gives them, each read into the Captures,
which the iteration yields every time: a global search that allocates nothing once the working memory has grown.

    c = Captures(re)
    for m in eachmatch!(c, text)
        r = capture_range(m, 1)
    end
"""
eachmatch!(c::Captures, s::Union{AbstractString,Utf8Text,Units,Bytes}) = CapturesMatches(c, (checked_units(s); s))

Base.IteratorSize(::Type{<:CapturesMatches}) = Base.SizeUnknown()
Base.eltype(::Type{<:CapturesMatches}) = Captures

# Inlined, so that the loop over it keeps the pair it returns (which holds the Captures) in registers: returned from a
# call, a pair that holds a reference is boxed.
@inline function Base.iterate(m::CapturesMatches, at::Int=0)
    c = m.c
    units = subject_units(m.subject)
    if at > length(units)
        c.found = false
        return nothing
    end
    from, to, found = exec_slots(c.re, units, at, c.re.flags.sticky, c.slots)
    c.found = found
    found || return nothing
    return c, next_start(c.re, units, from, to)
end
