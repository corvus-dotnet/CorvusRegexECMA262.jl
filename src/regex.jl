# A compiled pattern, its flags and groups, and its searches in either encoding (regex.rs and replace.rs). Positions here
# are 0-based offsets in the units of the text; the Base methods in api.jl give Julia's 1-based indices.

"""
    Flags

The flags of a pattern, as `new RegExp(pattern, flags)` reads them: `has_indices` (d), `global_` (g), `ignore_case`
(i), `multiline` (m), `dot_all` (s), `unicode` (u), `unicode_sets` (v) and `sticky` (y).
"""
struct Flags
    has_indices::Bool
    global_::Bool
    ignore_case::Bool
    multiline::Bool
    dot_all::Bool
    unicode::Bool
    unicode_sets::Bool
    sticky::Bool
end

"""
    FlagsError(message)

Flags that are not valid: a flag that is not one of dgimsuvy, a flag given twice, or u with v.
"""
struct FlagsError <: Exception
    msg::String
end

Base.showerror(io::IO, e::FlagsError) = print(io, e.msg)

"""
    EncodingError(message)

A pattern or a text that is not UTF-8, which is refused, never read as U+FFFD.
"""
struct EncodingError <: Exception
    msg::String
end

Base.showerror(io::IO, e::EncodingError) = print(io, e.msg)

const NOT_UTF8 = EncodingError("the text is not UTF-8")

"""
    InvalidPatternError(pattern, message, offset)

A pattern that is not valid under the grammar its flags choose: the reason, and the offset in the pattern's characters
(UTF-16 code units without the u or v flag).
"""
struct InvalidPatternError <: Exception
    pattern::String
    msg::String
    offset::Int
end

Base.showerror(io::IO, e::InvalidPatternError) = print(io, "$(e.msg) at offset $(e.offset) in $(repr(e.pattern))")

const FLAG_LETTERS = "dgimsuvy"

"""
    parse_flags(flags)

The flags written as `new RegExp` reads them, such as "giu". A flag that is not one of dgimsuvy, a flag given twice, or
u with v, is a FlagsError.
"""
function parse_flags(flags::AbstractString)
    on = falses(8)
    for c in flags
        k = findfirst(==(c), FLAG_LETTERS)
        k === nothing && throw(FlagsError("invalid flag $(repr(c)) in $(repr(flags))"))
        on[k] && throw(FlagsError("the flag $(repr(c)) is given twice in $(repr(flags))"))
        on[k] = true
    end
    on[6] && on[7] && throw(FlagsError("the flags u and v are given together in $(repr(flags))"))
    return Flags(on...)
end

"The flags as RegExp writes them, in the order dgimsuvy."
function Base.string(f::Flags)
    on = (f.has_indices, f.global_, f.ignore_case, f.multiline, f.dot_all, f.unicode, f.unicode_sets, f.sticky)
    return String([FLAG_LETTERS[k] for k in 1:8 if on[k]])
end

syntax(f::Flags) = Syntax(f.unicode || f.unicode_sets, f.unicode_sets, f.ignore_case, f.multiline, f.dot_all)

# The match timeout a pattern takes when it is compiled without one of its own, in nanoseconds; 0 for none.
const DEFAULT_MATCH_TIMEOUT = Threads.Atomic{Int}(0)

"""
    set_default_match_timeout!(seconds)

Gives every pattern compiled after it, without a timeout of its own, the match timeout. `nothing` or 0 is no timeout.
"""
function set_default_match_timeout!(seconds::Union{Nothing,Real})
    DEFAULT_MATCH_TIMEOUT[] = seconds === nothing ? 0 : max(round(Int, seconds * 1e9), 0)
    return nothing
end

"The match timeout a pattern compiled now without one of its own takes, in seconds, or `nothing`."
default_match_timeout() = DEFAULT_MATCH_TIMEOUT[] == 0 ? nothing : DEFAULT_MATCH_TIMEOUT[] / 1e9

"The name of one or more groups, in each encoding."
struct GroupInfoName
    name::String
    name16::Vector{UInt16}
    groups::Vector{Int}
end

"""
    EcmaRegex(pattern, flags = ""; match_timeout = default_match_timeout())

A pattern compiled as `new RegExp(pattern, flags)` compiles it: with the u or v flag by the grammar of the u flag and
matched by code point; with neither by the Annex B grammar and matched by UTF-16 code unit. The i, m and s flags are the
modifiers in force at the start of the pattern, which a modifier group such as `(?i:...)` changes for part of it.

A pattern can have a match timeout in seconds, as a Regex of .NET has: the time each match may take, which brings a cap
on the memory of its backtracking with it. A match that reaches a limit throws a MatchTimeoutError or a
MatchMemoryError. A pattern without a timeout never reaches a limit.

An invalid pattern throws an InvalidPatternError, a pattern over a limit of size a TooLargeError, and invalid flags a
FlagsError. A compiled pattern is safe to share between tasks.
"""
mutable struct EcmaRegex <: AbstractPattern
    pattern::String
    flags::Flags
    prog::Program
    # The program that records every group, built on the first match that reports them.
    @atomic caps::Union{Nothing,Program}
    groups::Int
    names::Vector{GroupInfoName}
    # The time each match may take, in nanoseconds; 0 for no limit.
    timeout::Int
end

function EcmaRegex(pattern::AbstractString, flags::AbstractString=""; match_timeout::Union{Nothing,Real}=default_match_timeout())
    EcmaRegex(pattern, parse_flags(flags); match_timeout)
end

function EcmaRegex(pattern::AbstractString, flags::Flags; match_timeout::Union{Nothing,Real}=default_match_timeout())
    pattern = String(pattern)
    isvalid(pattern) || throw(EncodingError("the pattern $(repr(pattern)) is not UTF-8"))
    root, ps = try
        parse_with(pattern, syntax(flags))
    catch e
        e isa SyntaxError && throw(InvalidPatternError(pattern, e.msg, e.offset))
        rethrow()
    end
    names = [GroupInfoName(String(Char.(n.name)), transcode(UInt16, String(Char.(n.name))), n.groups)
             for n in group_names(ps)]
    timeout = match_timeout === nothing ? 0 : max(round(Int, match_timeout * 1e9), 0)
    prog = compile_program(root, flags.unicode || flags.unicode_sets, -1)
    return EcmaRegex(pattern, flags, prog, nothing, ps.groups, names, timeout)
end

"""
    isvalid_pattern(pattern, flags = "")

Whether a pattern is valid with the flags.
"""
function isvalid_pattern(pattern::AbstractString, flags::AbstractString="")
    f = try
        parse_flags(flags)
    catch
        return false
    end
    isvalid(pattern) || return false
    try
        parse_with(pattern, syntax(f))
        return true
    catch e
        e isa SyntaxError && return false
        rethrow()
    end
end

"""
    @ecma_str pattern flags

The pattern compiled when the code is, as `r"..."` is: `ecma"(?<year>\\d{4})"u`.
"""
macro ecma_str(pattern, flags...)
    EcmaRegex(pattern, isempty(flags) ? "" : flags[1])
end

Base.show(io::IO, re::EcmaRegex) = print(io, "ecma\"", escape_string(re.pattern, '"'), "\"", string(re.flags))

"The pattern as it was compiled."
pattern(re::EcmaRegex) = re.pattern
"The pattern's flags."
flags(re::EcmaRegex) = re.flags
"The time each match may take in seconds, or `nothing` for no limit."
match_timeout(re::EcmaRegex) = re.timeout == 0 ? nothing : re.timeout / 1e9
"The number of capturing groups of the pattern."
group_count(re::EcmaRegex) = re.groups

"""
The name of each group, `nothing` for a group with no name. Two groups in separate alternatives can share a name.
"""
function group_names(re::EcmaRegex)
    names = Vector{Union{Nothing,String}}(nothing, re.groups)
    for n in re.names, g in n.groups
        names[g] = n.name
    end
    return names
end

"The groups with the name, which is more than one where groups in separate alternatives share it; empty for none."
function group_index(re::EcmaRegex, name::AbstractString)
    for n in re.names
        n.name == name && return copy(n.groups)
    end
    return Int[]
end

is_unicode(re::EcmaRegex) = re.flags.unicode || re.flags.unicode_sets

const CAPS_LOCK = ReentrantLock()

"The program that records every group."
function caps_program(re::EcmaRegex)
    re.prog.groups == re.groups && return re.prog
    caps = @atomic re.caps
    caps === nothing || return caps
    lock(CAPS_LOCK) do
        caps = @atomic re.caps
        caps === nothing || return caps
        root, _ = parse_with(re.pattern, syntax(re.flags))
        caps = compile_program(root, is_unicode(re), re.groups)
        @atomic re.caps = caps
        return caps
    end
end

"The groups of a name, in the encoding of a text."
function named(re::EcmaRegex, name::Bytes)
    for n in re.names
        equal_names(codeunits(n.name), name) && return n.groups
    end
    return Int[]
end

function named(re::EcmaRegex, name::Units)
    for n in re.names
        equal_names(n.name16, name) && return n.groups
    end
    return Int[]
end

equal_names(a::AbstractVector, b::AbstractVector) = length(a) == length(b) && all(k -> a[k] == b[k], eachindex(a, b))

"""
Finds the first match at or after `start` (at `start` alone with `sticky`), with the pattern's timeout, and returns
where it starts and ends and whether it was found. When `slots` is given it receives the start and end of the match and
of each group, -1 for a group that did not take part.
"""
function exec_slots(re::EcmaRegex, input::Text16or8, start::Int, sticky::Bool, slots::Union{Nothing,Vector{Int}})
    start = normalize(input, max(start, 0), is_unicode(re))
    slots === nothing && return exec(re.prog, input, start, sticky, re.timeout, nothing)
    from, to, found = exec_caps(caps_program(re), input, start, sticky, re.timeout, slots)
    if found
        slots[1], slots[2] = from, to
    end
    return from, to, found
end

# The matcher writes the groups after the whole match: slots[3:end].
function exec_caps(p::Program, input::Text16or8, start::Int, sticky::Bool, limit::Int, slots::Vector{Int})
    st = take_state()
    reset!(st, p, length(input), limit)
    from, found = search(p, st, input, start, sticky)
    to = st.end_
    stop = st.stop
    found && copyto!(slots, 3, st.caps, 1, length(st.caps))
    release!(st)
    give_state(st)
    throw_stop(stop, limit)
    return from, to, found
end

"The position a global search goes on from after a match from..to."
next_start(re::EcmaRegex, input::Text16or8, from::Int, to::Int) = to == from ? advance(input, to, is_unicode(re)) : to

"""
Each match of a global search, at most `n` (all when `n` is below 0), as its slots: with its groups when `submatch`,
the bounds of the whole match alone otherwise.
"""
function find_all(re::EcmaRegex, input::Text16or8, n::Int, submatch::Bool)
    out = Vector{Int}[]
    at = 0
    while n < 0 || length(out) < n
        slots = submatch ? Vector{Int}(undef, 2 * (re.groups + 1)) : nothing
        from, to, found = exec_slots(re, input, at, re.flags.sticky, slots)
        found || break
        push!(out, slots === nothing ? [from, to] : slots)
        at = next_start(re, input, from, to)
        at > length(input) && break
    end
    return out
end

"The units of a text, as the replacement is written into: bytes for UTF-8 and code units for UTF-16."
out_vector(::Bytes) = UInt8[]
out_vector(::Units) = UInt16[]

"""
The text with the first match, or every match with `all`, replaced by the template, as String.prototype.replace does,
with the template's \$ forms (\$\$, \$&, \$`, \$', \$n, \$nn and \$<name>) replaced. At most `count` matches are replaced.
"""
function replace_units(re::EcmaRegex, input::Text16or8, template::Text16or8, all::Bool; count::Int=typemax(Int))
    slots = Vector{Int}(undef, 2 * (re.groups + 1))
    out = out_vector(input)
    last, at, any_found, done = 0, 0, false, 0
    while at <= length(input) && done < count
        from, to, found = exec_slots(re, input, at, re.flags.sticky, slots)
        found || break
        any_found = true
        done += 1
        push_lossy!(out, input, last, from)
        substitute!(re, out, input, slots, template)
        last = to
        all || break
        at = next_start(re, input, from, to)
    end
    any_found || return nothing
    return push_lossy!(out, input, last, length(input))
end

"Appends the template with each \$ form replaced (GetSubstitution)."
function substitute!(re::EcmaRegex, out::Vector, input::Text16or8, slots::Vector{Int}, template::Text16or8)
    n = length(template)
    t(k) = Int(unit(template, k))
    digit(k) = k < n && UInt32('0') <= t(k) <= UInt32('9') ? t(k) - Int('0') : -1
    groups = length(slots) ÷ 2 - 1
    function group(g)
        slots[2g+1] != NONE && push_lossy!(out, input, slots[2g+1], slots[2g+2])
    end
    k = 0
    while k < n
        if t(k) != Int('$') || k + 1 >= n
            push!(out, unit(template, k))
            k += 1
            continue
        end
        next = t(k + 1)
        if next == Int('$')
            push!(out, unit(template, k))
            k += 2
        elseif next == Int('&')
            push_lossy!(out, input, slots[1], slots[2])
            k += 2
        elseif next == Int('`')
            push_lossy!(out, input, 0, slots[1])
            k += 2
        elseif next == Int('\'')
            push_lossy!(out, input, slots[2], length(input))
            k += 2
        elseif Int('0') <= next <= Int('9')
            d1, d2 = digit(k + 1), digit(k + 2)
            if d2 >= 0 && 1 <= d1 * 10 + d2 <= groups
                group(d1 * 10 + d2)
                k += 3
            elseif 1 <= d1 <= groups
                group(d1)
                k += 2
            else
                push!(out, unit(template, k))
                k += 1
            end
        elseif next == Int('<')
            # Without a named group $< is itself. With one, the name runs to the next >; a name that is no group's is the
            # empty string, and a < with no > after it is itself.
            close = -1
            for j in k+2:n-1
                if t(j) == Int('>')
                    close = j
                    break
                end
            end
            if close < 0 || isempty(re.names)
                push!(out, unit(template, k))
                k += 1
                continue
            end
            for g in named(re, view(template, k+3:close))
                if slots[2g+1] != NONE
                    group(g)
                    break
                end
            end
            k = close + 1
        else
            push!(out, unit(template, k))
            k += 1
        end
    end
    return out
end

"""
The text split around the matches (RegExp.prototype[Symbol.split]), as spans (from, to), (-1, -1) for a group that did
not take part, with at most `limit` items (all when `limit` is below 0). The flags g and y do not apply: split searches
with a copy of the pattern that is sticky, from each position in turn, which is what a search from the position finds
first.
"""
function split_units(re::EcmaRegex, input::Text16or8, limit::Int)
    size = length(input)
    out = Tuple{Int,Int}[]
    limit == 0 && return out
    slots = Vector{Int}(undef, 2 * (re.groups + 1))
    if size == 0
        _, _, found = exec_slots(re, input, 0, true, slots)
        found || push!(out, (0, 0))
        return out
    end
    p, q = 0, 0
    while q < size
        from, to, found = exec_slots(re, input, q, false, slots)
        (!found || from >= size) && break
        e = min(to, size)
        if e == p
            q = advance(input, from, is_unicode(re))
            continue
        end
        push!(out, (p, from))
        length(out) == limit && return out
        p = e
        for g in 1:length(slots)÷2-1
            push!(out, slots[2g+1] == NONE ? (NONE, NONE) : (slots[2g+1], slots[2g+2]))
            length(out) == limit && return out
        end
        q = p
    end
    push!(out, (p, size))
    return out
end
