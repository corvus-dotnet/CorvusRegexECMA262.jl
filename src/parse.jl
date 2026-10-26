# The parser: a pattern to its syntax tree, in either grammar, with the limits of size (parse.rs).

@enum NodeKind::UInt8 begin
    N_EMPTY
    N_CHAR
    N_SET
    N_CAT
    N_ALT
    N_GROUP
    N_REPEAT
    N_BOL
    N_EOL
    # ^ and $ inside a group with the m modifier.
    N_LINE_START
    N_LINE_END
    N_WORD_BOUNDARY
    N_NOT_WORD_BOUNDARY
    N_LOOK
    N_BACKREF
end

# The max of a quantifier with no upper bound.
const UNBOUNDED = -1

# Caps the bounds of a counted quantifier. No text that fits in memory reaches a larger count.
const MAX_COUNT = 2^31 - 1

# The limits on the size of one pattern. A pattern may come from outside, so reading and compiling one must take
# bounded time and memory whatever it holds. A pattern over a limit is refused with a TooLargeError, which is not the
# error of a pattern that is not valid.

"The longest pattern that is read, in bytes of UTF-8."
const MAX_PATTERN_LENGTH = 1 << 20
"The deepest groups nest, which bounds the recursion of the parser and of the compilers."
const MAX_NESTING = 1000
"""
The largest size a pattern may have, in the bytes the parser counts for it: NODE_SIZE for each node of its syntax
tree, and RANGE_SIZE for each range of a class as its members are read, for each range a case insensitive group or a
negated property adds, for each alternative that encloses a named group and for each group that shares its name. The
tree, the program compiled from it and the time to make both are proportional to that size, so it bounds them all: a
pattern at the limit takes a few milliseconds and a few megabytes.
"""
const MAX_SIZE = 1 << 20

const NODE_SIZE = 32
const RANGE_SIZE = 8

"Which limit of size a pattern is over: `LIMIT_LENGTH`, `LIMIT_NESTING` or `LIMIT_SIZE`."
@enum Limit::UInt8 LIMIT_LENGTH LIMIT_NESTING LIMIT_SIZE

"""
    TooLargeError(limit, value)

A pattern over one of the limits of size: `limit` names it and `value` is its value. The pattern was not read to its
end, so the error says nothing of whether it is valid.
"""
struct TooLargeError <: Exception
    limit::Limit
    value::Int
end

function Base.showerror(io::IO, e::TooLargeError)
    if e.limit == LIMIT_LENGTH
        print(io, "the pattern is longer than $(e.value) bytes")
    elseif e.limit == LIMIT_NESTING
        print(io, "the groups of the pattern nest more than $(e.value) deep")
    else
        print(io, "the pattern has a size of more than $(e.value) bytes when it is read")
    end
end

"""
    SyntaxError(message, offset)

A pattern that is not valid under the chosen grammar: the reason, and the offset in the pattern's characters.
"""
struct SyntaxError <: Exception
    msg::String
    offset::Int
end

Base.showerror(io::IO, e::SyntaxError) = print(io, e.msg)

"One element of the syntax tree of a pattern."
mutable struct Node
    kind::NodeKind
    # The code point of an N_CHAR.
    r::Int
    # The class of an N_SET.
    set::Union{Nothing,CharSet}
    # The children of N_CAT and N_ALT, and the one child of N_GROUP, N_REPEAT and N_LOOK.
    subs::Vector{Node}
    # min, max and lazy describe an N_REPEAT.
    min::Int
    max::Int
    lazy::Bool
    # The number of the capturing group of an N_GROUP, counted from 1; 0 for a group that does not capture.
    group::Int
    # The groups an N_BACKREF names. A name can belong to several groups in separate alternatives, of which at most one
    # has taken part at any time.
    groups::Vector{Int}
    # The group name of a named backreference until it is resolved.
    name::Vector{Int}
    # Marks an N_BACKREF, N_WORD_BOUNDARY or N_NOT_WORD_BOUNDARY inside a case-insensitive group.
    fold::Bool
    # behind and negative describe an N_LOOK.
    behind::Bool
    negative::Bool
end

Node(kind::NodeKind) = Node(kind, 0, nothing, Node[], 0, 0, false, 0, Int[], Int[], false, false, false)
with_subs(kind::NodeKind, subs::Node...) = (n = Node(kind); append!(n.subs, subs); n)
char_node(r::Int) = (n = Node(N_CHAR); n.r = r; n)
set_node(set::CharSet) = (n = Node(N_SET); n.set = set; n)
function repeat_node(atom::Node, min::Int, max::Int, lazy::Bool)
    n = with_subs(N_REPEAT, atom)
    n.min, n.max, n.lazy = min, max, lazy
    return n
end
function group_node(body::Node, group::Int)
    n = with_subs(N_GROUP, body)
    n.group = group
    return n
end
function look_node(body::Node, negative::Bool, behind::Bool)
    n = with_subs(N_LOOK, body)
    n.negative, n.behind = negative, behind
    return n
end
function backref_node(groups::Vector{Int}, name::Vector{Int}, fold::Bool)
    n = Node(N_BACKREF)
    n.groups, n.name, n.fold = groups, name, fold
    return n
end

"Names one alternative of one disjunction."
mutable struct Branch
    disjunction::Int
    alternative::Int
end

"A capturing group with a name, and the alternatives that enclose it."
struct NamedGroup
    group::Int
    path::Vector{Branch}
end

"A group name with the groups that have it."
struct GroupName
    name::Vector{Int}
    groups::Vector{Int}
end

"""
The grammar a pattern is read with and the flags that change what its atoms mean. `unicode` is the grammar of the u
flag (without it, the Annex B grammar of a pattern with no u or v flag); `sets` is the grammar of the v flag inside a
class, and the properties of strings, and comes with `unicode`; `icase`, `multiline` and `dot_all` are the i, m and s
flags: the modifiers in force at the start of the pattern.
"""
struct Syntax
    unicode::Bool
    sets::Bool
    icase::Bool
    multiline::Bool
    dot_all::Bool
end

"""
Reads a pattern by recursive descent. With `unicode` set it applies the grammar of the u flag. Without it, it applies
the Annex B grammar of patterns with no flag.
"""
mutable struct Parser
    # The pattern as code points with the u flag, and as UTF-16 code units without it (see code_units).
    p::Vector{Int}
    # The 0-based position in p.
    i::Int
    unicode::Bool
    # The grammar of the v flag.
    sets::Bool
    # The sequences of the property of strings the last class escape named (the v flag), or nothing.
    escape_strings::Union{Nothing,Vector{Vector{Int}}}
    depth::Int
    # group_count and has_names come from a scan of the whole pattern before parsing, because the meaning of \1 and \k
    # depends on groups that may follow them.
    group_count::Int
    has_names::Bool
    groups::Int
    # The groups of each name, keyed by the name's code points.
    names::Dict{Vector{Int},Vector{NamedGroup}}
    named_refs::Bool
    # The alternatives that enclose the current position, innermost last.
    path::Vector{Branch}
    disjunctions::Int
    # The modifiers in force, which only a group such as (?i:...) changes.
    icase::Bool
    multiline::Bool
    dot_all::Bool
    # Records that the pattern has a construct only the backtracking matcher can run.
    needs_backtracking::Bool
    # The size of what has been read so far (see MAX_SIZE).
    size::Int
end

const ANY_SET = CharSet(Int[0, MAX_RUNE])
const DIGIT_SET = CharSet(DIGIT_PAIRS)
const NOT_DIGIT_SET = CharSet(DIGIT_PAIRS, true)
const WORD_SET = CharSet(WORD_PAIRS)
const NOT_WORD_SET = CharSet(WORD_PAIRS, true)
const SPACE_SET = CharSet(SPACE_PAIRS)
const NOT_SPACE_SET = CharSet(SPACE_PAIRS, true)

"""
Reads the pattern, and returns its syntax tree and the parser. It throws a SyntaxError for a pattern that is not valid
under the chosen grammar, and a TooLargeError for a pattern over a limit of size, which it stops reading at the limit.
"""
function parse_with(pattern::AbstractString, sx::Syntax)
    ncodeunits(pattern) > MAX_PATTERN_LENGTH && throw(TooLargeError(LIMIT_LENGTH, MAX_PATTERN_LENGTH))
    p = Int[codepoint(c) for c in pattern]
    sx.unicode || (p = code_units(p))
    ps = Parser(p, 0, sx.unicode, sx.sets, nothing, 0, 0, false, 0, Dict{Vector{Int},Vector{NamedGroup}}(), false,
        Branch[], 0, sx.icase, sx.multiline, sx.dot_all, false, 0)
    scan_groups!(ps)
    root = disjunction!(ps)
    if ps.i < length(ps.p)
        at(ps, ps.i) == Int(')') && fail(ps, "unmatched ')'")
        fail(ps, "unexpected character")
    end
    ps.named_refs && resolve!(ps, root)
    return root, ps
end

"""
The UTF-16 code units of a pattern. Without the u flag ECMA-262 reads a pattern, and matches a text, a code unit at a
time. A character beyond the Basic Multilingual Plane is then two atoms, a quantifier after it repeats the second, and
in a class it is two members, so a range between two such characters runs from a low surrogate to a high one and is
an error.
"""
function code_units(p::Vector{Int})
    any(>(0xFFFF), p) || return p
    units = Int[]
    sizehint!(units, length(p) + 8)
    for c in p
        if c > 0xFFFF
            push!(units, high_surrogate(c), low_surrogate(c))
        else
            push!(units, c)
        end
    end
    return units
end

is_digit(c::Int) = Int('0') <= c <= Int('9')

"""
Whether the first of two runs of decimal digits is the greater number. The runs are compared as written, because a
count has no limit of size in the grammar and `number!` stops at MAX_COUNT.
"""
function greater_as_written(a::AbstractVector{Int}, b::AbstractVector{Int})
    a = a[something(findfirst(!=(Int('0')), a), length(a) + 1):end]
    b = b[something(findfirst(!=(Int('0')), b), length(b) + 1):end]
    length(a) != length(b) && return length(a) > length(b)
    for k in eachindex(a)
        a[k] != b[k] && return a[k] > b[k]
    end
    return false
end

"Whether two positions lie in different alternatives of some disjunction."
function separate_alternatives(a::Vector{Branch}, b::Vector{Branch})
    for k in 1:min(length(a), length(b))
        a[k].disjunction != b[k].disjunction && break
        a[k].alternative != b[k].alternative && return true
    end
    return false
end

function hex_value(c::Int)
    Int('0') <= c <= Int('9') && return c - Int('0')
    Int('a') <= c <= Int('f') && return c - Int('a') + 10
    Int('A') <= c <= Int('F') && return c - Int('A') + 10
    return -1
end

is_ascii_letter(c::Int) = Int('a') <= c <= Int('z') || Int('A') <= c <= Int('Z')

"Whether c is one of the ASCII characters of `set`."
in_ascii(c::Int, set::String) = 0 <= c < 0x80 && Char(c) in set

"Whether c is one of the characters the u flag lets an identity escape name."
syntax_character(c::Int) = in_ascii(c, raw"^$\.*+?()[]{}|/")

const ID_START = must_binary_table("ID_Start")
const ID_CONTINUE = must_binary_table("ID_Continue")

function append_class_atom!(pairs::Vector{Int}, c::Int, set::Union{Nothing,CharSet})
    set === nothing ? push!(pairs, c, c) : append!(pairs, set.ranges)
end

"The names of the groups, each with the groups that have it, in the order of their first group."
function group_names(ps::Parser)
    names = [GroupName(name, [g.group for g in groups]) for (name, groups) in ps.names]
    sort!(names, by=n -> n.groups[1])
    return names
end

@inline at(ps::Parser, k::Int) = @inbounds ps.p[k+1]

"Adds to the size of the pattern, and stops the parser when the size is over its limit."
function charge!(ps::Parser, bytes::Int)
    ps.size += bytes
    ps.size > MAX_SIZE && throw(TooLargeError(LIMIT_SIZE, MAX_SIZE))
    return nothing
end

fail(ps::Parser, msg::String) = throw(SyntaxError(msg, ps.i))

"Gives every named backreference the groups of its name. A name no group has is an error."
function resolve!(ps::Parser, n::Node)
    if n.kind == N_BACKREF && !isempty(n.name)
        named = get(ps.names, n.name, nothing)
        named === nothing && fail(ps, "reference to an unknown group name")
        for g in named
            push!(n.groups, g.group)
        end
    end
    for sub in n.subs
        resolve!(ps, sub)
    end
end

"Counts the capturing groups of the pattern and notes whether any is named."
function scan_groups!(ps::Parser)
    in_class = false
    s = ps.p
    k = 1
    while k <= length(s)
        c = s[k]
        if c == Int('\\')
            k += 1
        elseif c == Int('[')
            in_class = true
        elseif c == Int(']')
            in_class = false
        elseif c == Int('(') && !in_class
            if k + 1 > length(s) || s[k+1] != Int('?')
                ps.group_count += 1
            elseif k + 3 <= length(s) && s[k+2] == Int('<') && s[k+3] != Int('=') && s[k+3] != Int('!')
                ps.group_count += 1
                ps.has_names = true
            end
        end
        k += 1
    end
end

more(ps::Parser) = ps.i < length(ps.p)
peek(ps::Parser) = ps.i < length(ps.p) ? at(ps, ps.i) : -1

function eat!(ps::Parser, c::Char)
    if ps.i < length(ps.p) && at(ps, ps.i) == Int(c)
        ps.i += 1
        return true
    end
    return false
end

is(c::Int, ch::Char) = c == Int(ch)

function disjunction!(ps::Parser)
    ps.depth += 1
    ps.depth > MAX_NESTING && throw(TooLargeError(LIMIT_NESTING, MAX_NESTING))
    ps.disjunctions += 1
    push!(ps.path, Branch(ps.disjunctions, 0))
    last = length(ps.path)
    first = alternative!(ps)
    if !is(peek(ps), '|')
        resize!(ps.path, last - 1)
        ps.depth -= 1
        return first
    end
    alt = with_subs(N_ALT, first)
    while eat!(ps, '|')
        charge!(ps, NODE_SIZE)
        ps.path[last].alternative += 1
        push!(alt.subs, alternative!(ps))
    end
    resize!(ps.path, last - 1)
    ps.depth -= 1
    return alt
end

function alternative!(ps::Parser)
    terms = Node[]
    while more(ps) && !is(peek(ps), '|') && !is(peek(ps), ')')
        push!(terms, term!(ps))
    end
    isempty(terms) && return Node(N_EMPTY)
    length(terms) == 1 && return terms[1]
    return with_subs(N_CAT, terms...)
end

"""
The node for one literal character. Inside a case-insensitive group that is the class of the characters equivalent to
it.
"""
function char_node_of(ps::Parser, c::Int)
    if ps.icase
        set, _ = fold_closure(CharSet(Int[c, c]), ps.unicode)
        (length(set.ranges) != 2 || set.ranges[1] != set.ranges[2]) && return set_node(set)
    end
    return char_node(c)
end

"""
The node for a class. Inside a case-insensitive group the class also takes every character equivalent to one of its
members.
"""
set_node_of(ps::Parser, set::CharSet) = set_node(ps.icase ? fold!(ps, set) : set)

"""
The set with every character equivalent to one of its members. It charges the pattern for the work and for the set: a
byte for each character with a case variant that the set holds, and its ranges.
"""
function fold!(ps::Parser, set::CharSet)
    closed, variants = fold_closure(set, ps.unicode)
    charge!(ps, variants + RANGE_SIZE * length(closed.ranges) ÷ 2)
    return closed
end

function term!(ps::Parser)
    # The atom, and the repetition or the group around it.
    charge!(ps, 2 * NODE_SIZE)
    c = peek(ps)
    quantifiable = true
    if is(c, '^')
        ps.i += 1
        quantifiable = false
        if ps.multiline
            ps.needs_backtracking = true
            atom = Node(N_LINE_START)
        else
            atom = Node(N_BOL)
        end
    elseif is(c, '$')
        ps.i += 1
        quantifiable = false
        if ps.multiline
            ps.needs_backtracking = true
            atom = Node(N_LINE_END)
        else
            atom = Node(N_EOL)
        end
    elseif is(c, '(')
        atom, quantifiable = group!(ps)
    elseif is(c, '.')
        ps.i += 1
        atom = set_node(ps.dot_all ? ANY_SET : DOT_SET)
    elseif is(c, '[')
        atom = class!(ps)
    elseif is(c, '\\')
        atom, quantifiable = atom_escape!(ps)
    elseif is(c, '*') || is(c, '+') || is(c, '?')
        fail(ps, "nothing to repeat")
    elseif is(c, '{')
        (ps.unicode || looks_like_quantifier(ps)) && fail(ps, "nothing to repeat")
        ps.i += 1
        atom = char_node_of(ps, Int('{'))
    elseif is(c, ']') || is(c, '}')
        ps.unicode && fail(ps, "lone bracket")
        ps.i += 1
        atom = char_node_of(ps, c)
    else
        ps.i += 1
        atom = char_node_of(ps, c)
    end
    q = quantifier!(ps)
    q === nothing && return atom
    quantifiable || fail(ps, "nothing to repeat")
    return repeat_node(atom, q...)
end

"Whether the text at the current { reads as {n}, {n,} or {n,m}."
function looks_like_quantifier(ps::Parser)
    s = ps.p
    n = length(s)
    k = ps.i + 1
    start = k
    while k < n && is_digit(s[k+1])
        k += 1
    end
    (k == start || k >= n) && return false
    is(s[k+1], '}') && return true
    is(s[k+1], ',') || return false
    k += 1
    while k < n && is_digit(s[k+1])
        k += 1
    end
    return k < n && is(s[k+1], '}')
end

"Reads a run of decimal digits, saturating at MAX_COUNT."
function number!(ps::Parser)
    start = ps.i
    v = 0
    while ps.i < length(ps.p) && is_digit(at(ps, ps.i))
        if v < MAX_COUNT
            v = min(v * 10 + (at(ps, ps.i) - Int('0')), MAX_COUNT)
        end
        ps.i += 1
    end
    start == ps.i && fail(ps, "expected a number")
    return v
end

"""
Reads a quantifier, when one is here: its bounds, and whether it is lazy, as a tuple; `nothing` when there is none.
"""
function quantifier!(ps::Parser)
    c = peek(ps)
    if is(c, '*')
        ps.i += 1
        lo, hi = 0, UNBOUNDED
    elseif is(c, '+')
        ps.i += 1
        lo, hi = 1, UNBOUNDED
    elseif is(c, '?')
        ps.i += 1
        lo, hi = 0, 1
    elseif is(c, '{') && looks_like_quantifier(ps)
        ps.i += 1
        first = ps.i
        lo = number!(ps)
        hi = lo
        first_end = ps.i
        if eat!(ps, ',')
            if is(peek(ps), '}')
                hi = UNBOUNDED
            else
                second = ps.i
                hi = number!(ps)
                # Both counts stop at MAX_COUNT, so the numbers are compared as they are written.
                if greater_as_written(view(ps.p, first+1:first_end), view(ps.p, second+1:ps.i))
                    fail(ps, "numbers out of order in quantifier")
                end
            end
        end
        eat!(ps, '}') || fail(ps, "malformed quantifier")
    else
        return nothing
    end
    return lo, hi, eat!(ps, '?')
end

"Reads a group or a lookaround, and whether a quantifier may follow it."
function group!(ps::Parser)
    ps.i += 1
    eat!(ps, '?') || return capture!(ps, nothing), true
    if eat!(ps, ':')
        body = disjunction!(ps)
        close!(ps)
        return with_subs(N_GROUP, body), true
    end
    c = peek(ps)
    (is(c, 'i') || is(c, 'm') || is(c, 's') || is(c, '-')) && return modifier_group!(ps), true
    if eat!(ps, '=') || eat!(ps, '!')
        negative = is(at(ps, ps.i - 1), '!')
        body = disjunction!(ps)
        close!(ps)
        ps.needs_backtracking = true
        # Annex B lets a quantifier follow a lookahead. The u flag does not.
        return look_node(body, negative, false), !ps.unicode
    end
    if eat!(ps, '<')
        if eat!(ps, '=') || eat!(ps, '!')
            negative = is(at(ps, ps.i - 1), '!')
            body = disjunction!(ps)
            close!(ps)
            ps.needs_backtracking = true
            return look_node(body, negative, true), false
        end
        name = group_name!(ps)
        # Two groups may share a name only when they are in separate alternatives of one disjunction, so that no match
        # can go through both.
        for other in get(ps.names, name, NamedGroup[])
            separate_alternatives(other.path, ps.path) || fail(ps, "duplicate group name")
        end
        return capture!(ps, name), true
    end
    fail(ps, "invalid group")
end

"""
Reads a group that turns modifiers on or off for its body, such as (?i:...) or (?s-i:...). The position is after the
(?.
"""
function modifier_group!(ps::Parser)
    icase, multiline, dot_all = ps.icase, ps.multiline, ps.dot_all
    seen = falses(3)
    removing, count = false, 0
    while !eat!(ps, ':')
        c = peek(ps)
        ps.i += 1
        if is(c, 'i')
            flag, ps.icase = 1, !removing
        elseif is(c, 'm')
            flag, ps.multiline = 2, !removing
        elseif is(c, 's')
            flag, ps.dot_all = 3, !removing
        elseif is(c, '-')
            removing && fail(ps, "invalid group modifier")
            removing = true
            continue
        else
            fail(ps, "invalid group modifier")
        end
        seen[flag] && fail(ps, "repeated group modifier")
        seen[flag] = true
        count += 1
    end
    count == 0 && fail(ps, "invalid group modifier")
    body = disjunction!(ps)
    close!(ps)
    ps.icase, ps.multiline, ps.dot_all = icase, multiline, dot_all
    return with_subs(N_GROUP, body)
end

function capture!(ps::Parser, name::Union{Nothing,Vector{Int}})
    ps.groups += 1
    group = ps.groups
    if name !== nothing
        # The path is kept, and every group of the same name is compared with it.
        named = get!(Vector{NamedGroup}, ps.names, name)
        charge!(ps, RANGE_SIZE * (length(ps.path) + length(named)))
        push!(named, NamedGroup(group, [Branch(b.disjunction, b.alternative) for b in ps.path]))
    end
    body = disjunction!(ps)
    close!(ps)
    return group_node(body, group)
end

close!(ps::Parser) = eat!(ps, ')') || fail(ps, "unterminated group")

"Reads a group name up to and including its >. A character of the name may be written as a \\u escape."
function group_name!(ps::Parser)
    name = Int[]
    while !eat!(ps, '>')
        more(ps) || fail(ps, "invalid group name")
        c = peek(ps)
        ps.i += 1
        if is(c, '\\')
            eat!(ps, 'u') || fail(ps, "invalid group name")
            c = unicode_escape!(ps, true)
            c < 0 && fail(ps, "invalid group name")
        elseif 0xD800 <= c <= 0xDBFF && 0xDC00 <= peek(ps) <= 0xDFFF
            # Without the u flag the pattern is code units, and a name still takes a surrogate pair as one character.
            c = 0x10000 + (c - 0xD800) << 10 + (peek(ps) - 0xDC00)
            ps.i += 1
        end
        if isempty(name)
            (is(c, '$') || is(c, '_') || UCD.contains(ID_START, c)) || fail(ps, "invalid group name")
        elseif !(is(c, '$') || c == 0x200C || c == 0x200D || UCD.contains(ID_CONTINUE, c))
            fail(ps, "invalid group name")
        end
        push!(name, c)
    end
    isempty(name) && fail(ps, "invalid group name")
    return name
end

"Reads an escape outside a class, and whether a quantifier may follow it."
function atom_escape!(ps::Parser)
    ps.i += 1
    more(ps) || fail(ps, "\\ at end of pattern")
    c = peek(ps)
    if is(c, 'b') || is(c, 'B')
        ps.i += 1
        boundary = Node(is(c, 'B') ? N_NOT_WORD_BOUNDARY : N_WORD_BOUNDARY)
        # With the u flag, a case-insensitive word boundary counts two more characters as word characters.
        if ps.unicode && ps.icase
            boundary.fold = true
            ps.needs_backtracking = true
        end
        return boundary, false
    end
    if is(c, 'k')
        # Annex B reads \k as the letter k in a pattern with no named group.
        if ps.unicode || ps.has_names
            ps.i += 1
            eat!(ps, '<') || fail(ps, "invalid named reference")
            name = group_name!(ps)
            ps.named_refs = true
            ps.needs_backtracking = true
            return backref_node(Int[], name, ps.icase), true
        end
        ps.i += 1
        return char_node_of(ps, Int('k')), true
    end
    if Int('1') <= c <= Int('9')
        start = ps.i
        n = number!(ps)
        if n <= ps.group_count
            ps.needs_backtracking = true
            return backref_node(Int[n], Int[], ps.icase), true
        end
        ps.unicode && fail(ps, "reference to a group that does not exist")
        # Annex B reads it as an octal escape, or as the digit itself.
        ps.i = start
        return char_node_of(ps, legacy_octal!(ps)), true
    end
    set = class_escape!(ps, c)
    if set !== nothing
        strs = ps.escape_strings
        if strs !== nothing
            # A property of strings (the v flag): the class of its code points and its sequences.
            return class_node(ps, strings_value(ps, fold_if!(ps, set), strs), false), true
        end
        return set_node_of(ps, set), true
    end
    return char_node_of(ps, character_escape!(ps, false)), true
end

"""
Reads an Annex B octal escape of up to three digits with a value below 256. A digit that cannot start one (8 or 9)
stands for itself.
"""
function legacy_octal!(ps::Parser)
    v = 0
    k = 0
    while k < 3 && more(ps) && Int('0') <= peek(ps) <= Int('7') && v * 8 + (peek(ps) - Int('0')) <= 0o377
        v = v * 8 + (peek(ps) - Int('0'))
        ps.i += 1
        k += 1
    end
    if k == 0
        d = peek(ps)
        ps.i += 1
        return d
    end
    return v
end

"""
Reads a class escape such as \\d or \\p{...} whose letter is c. It returns `nothing`, consuming nothing, when c does
not start one.
"""
function class_escape!(ps::Parser, c::Int)
    ps.escape_strings = nothing
    if is(c, 'd')
        set = DIGIT_SET
    elseif is(c, 'D')
        set = NOT_DIGIT_SET
    elseif is(c, 'w')
        set = ps.unicode && ps.icase ? FOLD_WORD_SET : WORD_SET
    elseif is(c, 'W')
        set = ps.unicode && ps.icase ? NOT_FOLD_WORD_SET : NOT_WORD_SET
    elseif is(c, 's')
        set = SPACE_SET
    elseif is(c, 'S')
        set = NOT_SPACE_SET
    elseif is(c, 'p') || is(c, 'P')
        # Without the u flag \p is the letter p.
        ps.unicode || return nothing
        ps.i += 1
        eat!(ps, '{') || fail(ps, "invalid property name")
        start = ps.i
        while more(ps) && !is(peek(ps), '}')
            ps.i += 1
        end
        # A name ECMA-262 defines is ASCII. Any other character makes a name no table has.
        expr = String(Char.(view(ps.p, start+1:ps.i)))
        eat!(ps, '}') || fail(ps, "invalid property name")
        found = property_set(expr)
        if found === nothing
            if ps.sets && is(c, 'p')
                property = string_property_of(expr)
                if property !== nothing
                    # A property of strings, which the v flag alone names, and which has no complement.
                    charge!(ps, RANGE_SIZE * (length(property.set.ranges) ÷ 2 + length(property.strings)))
                    ps.escape_strings = property.strings
                    return property.set
                end
            end
            fail(ps, "invalid property name")
        end
        if is(c, 'P')
            charge!(ps, RANGE_SIZE * length(found.ranges) ÷ 2)
            # With the v flag the complement is of the case-folded set; with the u flag the fold comes after it.
            ps.sets && (found = fold_if!(ps, found))
            return CharSet(found.ranges, true)
        end
        return found
    else
        return nothing
    end
    ps.i += 1
    return set
end

"Reads exactly n hexadecimal digits. It returns -1, consuming nothing, when they are not there."
function hex!(ps::Parser, n::Int)
    ps.i + n > length(ps.p) && return -1
    v = 0
    for k in 0:n-1
        d = hex_value(at(ps, ps.i + k))
        d < 0 && return -1
        v = v * 16 + d
    end
    ps.i += n
    return v
end

"Reads the escape after a backslash, in or out of a class, and returns the code point it names."
function character_escape!(ps::Parser, in_class::Bool)
    c = peek(ps)
    ps.i += 1
    is(c, 'f') && return 0x0C % Int
    is(c, 'n') && return 0x0A % Int
    is(c, 'r') && return 0x0D % Int
    is(c, 't') && return 0x09 % Int
    is(c, 'v') && return 0x0B % Int
    if is(c, 'c')
        l = peek(ps)
        if is_ascii_letter(l)
            ps.i += 1
            return l % 32
        end
        if !ps.unicode && in_class && (is_digit(l) || is(l, '_'))
            ps.i += 1
            return l % 32
        end
        ps.unicode && fail(ps, "invalid control escape")
        # Annex B reads a \c that is not a control escape as a backslash followed by the letter c.
        ps.i -= 1
        return Int('\\')
    end
    if is(c, '0')
        if more(ps) && is_digit(peek(ps))
            ps.unicode && fail(ps, "invalid decimal escape")
            ps.i -= 1
            return legacy_octal!(ps)
        end
        return 0
    end
    if is(c, 'x')
        h = hex!(ps, 2)
        if h < 0
            ps.unicode && fail(ps, "invalid \\x escape")
            return Int('x')
        end
        return h
    end
    if is(c, 'u')
        u = unicode_escape!(ps, ps.unicode)
        if u < 0
            ps.unicode && fail(ps, "invalid \\u escape")
            return Int('u')
        end
        return u
    end
    if Int('1') <= c <= Int('9') && !ps.unicode && in_class
        ps.i -= 1
        return legacy_octal!(ps)
    end
    # Identity escapes. The u flag allows only the syntax characters and '/', and '-' in a class. Annex B allows any
    # character, except k in a pattern with a named group. Outside a class atom_escape! reads \k before this is
    # reached, so here the \k of such a pattern is in a class, where it is not a reference either.
    ps.unicode && !syntax_character(c) && !(in_class && is(c, '-')) && fail(ps, "invalid escape")
    is(c, 'k') && ps.has_names && fail(ps, "invalid escape")
    return c
end

"""
Reads what follows a \\u and returns the code point, or -1, consuming nothing, when it is not a well-formed escape.
With `unicode_mode` set, as it is with the u flag and always in a group name, it accepts the \\u{...} form and reads a
surrogate pair written as two escapes as one code point. Without it each escape is one code unit.
"""
function unicode_escape!(ps::Parser, unicode_mode::Bool)
    start = ps.i
    if unicode_mode && eat!(ps, '{')
        digits = ps.i
        v = 0
        while more(ps) && hex_value(peek(ps)) >= 0
            v <= MAX_RUNE && (v = v * 16 + hex_value(peek(ps)))
            ps.i += 1
        end
        if digits == ps.i || !eat!(ps, '}') || v > MAX_RUNE
            ps.i = start
            return -1
        end
        return v
    end
    u = hex!(ps, 4)
    u < 0 && return -1
    if unicode_mode && 0xD800 <= u <= 0xDBFF && ps.i + 6 <= length(ps.p) && is(at(ps, ps.i), '\\') &&
       is(at(ps, ps.i + 1), 'u')
        save = ps.i
        ps.i += 2
        low = hex!(ps, 4)
        0xDC00 <= low <= 0xDFFF && return 0x10000 + (u - 0xD800) << 10 + (low - 0xDC00)
        ps.i = save
    end
    return u
end

"Reads a character class from its [ to its ]."
function class!(ps::Parser)
    ps.sets && return class_set_expression!(ps)
    ps.i += 1
    negated = eat!(ps, '^')
    pairs = Int[]
    # The number of ranges read so far that the size of the pattern has been charged for.
    charged = 0
    while true
        more(ps) || fail(ps, "unterminated character class")
        eat!(ps, ']') && break
        charge!(ps, RANGE_SIZE * (length(pairs) ÷ 2 - charged))
        charged = length(pairs) ÷ 2
        first, first_set = class_atom!(ps)
        if is(peek(ps), '-') && ps.i + 1 < length(ps.p) && !is(at(ps, ps.i + 1), ']')
            ps.i += 1
            second, second_set = class_atom!(ps)
            if first_set !== nothing || second_set !== nothing
                ps.unicode && fail(ps, "invalid character class range")
                # Annex B reads the '-' as itself when a class escape is at either end.
                append_class_atom!(pairs, first, first_set)
                push!(pairs, Int('-'), Int('-'))
                append_class_atom!(pairs, second, second_set)
                continue
            end
            second < first && fail(ps, "range out of order in character class")
            push!(pairs, first, second)
            continue
        end
        append_class_atom!(pairs, first, first_set)
    end
    # Inside a case-insensitive group a character matches the class when it is equivalent to a member, and a negated
    # class excludes exactly those characters.
    charge!(ps, RANGE_SIZE * (length(pairs) ÷ 2 - charged))
    set = CharSet(pairs)
    ps.icase && (set = fold!(ps, set))
    negated && (set = CharSet(set.ranges, true))
    return set_node(set)
end

"Reads one member of a class: a code point and nothing, or 0 and a set for a class escape."
function class_atom!(ps::Parser)
    c = peek(ps)
    ps.i += 1
    is(c, '\\') || return c, nothing
    more(ps) || fail(ps, "\\ at end of pattern")
    e = peek(ps)
    if is(e, 'b')
        ps.i += 1
        return 0x08 % Int, nothing
    end
    set = class_escape!(ps, e)
    set === nothing || return 0, set
    return character_escape!(ps, true), nothing
end

# The v flag. Its grammar changes a class and nothing outside it. A class is read as a value of two parts, its code
# points and its strings (each of a length other than one, the empty string among them), with a flag for whether its
# syntax may hold a string, which ECMA-262's MayContainStrings decides from the syntax and not from what the strings
# turn out to be. A string of one character is a character of the class. The union, the intersection (&&) and the
# difference (--) act on both parts, strings compared whole. With the i flag each operand is case folded as it is
# read, so that the complement of a class, and of \P{...}, is of the folded set (with the u flag the fold comes after
# the complement). A class with strings is a group of an alternation: the strings longest first, each a sequence of
# characters, then the set. (This is the design of the .NET reference engine, section 3.2.)

"""
The value of a class of the v flag's grammar: its code points, its strings (each of a length other than one, the empty
string among them), and whether its syntax may hold a string.
"""
struct ClassSetValue
    set::CharSet
    strings::Vector{Vector{Int}}
    may_contain_strings::Bool
end

empty_class_set_value() = ClassSetValue(CharSet(Int[]), Vector{Int}[], false)
class_set_value_of(set::CharSet) = ClassSetValue(set, Vector{Int}[], false)

function Base.union(a::ClassSetValue, b::ClassSetValue)
    strs = copy(a.strings)
    for s in b.strings
        s in strs || push!(strs, s)
    end
    return ClassSetValue(union(a.set, b.set), strs, a.may_contain_strings || b.may_contain_strings)
end

function Base.intersect(a::ClassSetValue, b::ClassSetValue)
    strs = [s for s in a.strings if s in b.strings]
    return ClassSetValue(intersect(a.set, b.set), strs, a.may_contain_strings && b.may_contain_strings)
end

function subtract(a::ClassSetValue, b::ClassSetValue)
    strs = [s for s in a.strings if !(s in b.strings)]
    return ClassSetValue(subtract(a.set, b.set), strs, a.may_contain_strings)
end

"""
The set with every character equivalent to one of its members, inside a case-insensitive group, and the set itself
outside one.
"""
fold_if!(ps::Parser, set::CharSet) = ps.icase ? fold!(ps, set) : set

"Reads a class of the v flag's grammar from its [ to its ]."
function class_set_expression!(ps::Parser)
    ps.i += 1
    negated = eat!(ps, '^')
    start = ps.i
    value = class_set_contents!(ps)
    eat!(ps, ']') || fail(ps, "unterminated character class")
    if negated && value.may_contain_strings
        ps.i = start
        fail(ps, "negated character class may contain strings")
    end
    return class_node(ps, value, negated)
end

"Reads the contents of a class of the v flag's grammar, up to its ]."
function class_set_contents!(ps::Parser)
    is(peek(ps), ']') && return empty_class_set_value()
    value, is_range = class_set_element!(ps)
    op = set_operator(ps)
    if op != 0
        # An intersection or a difference: operands only, with the one operator between every two.
        is_range && fail(ps, "invalid set operation in character class")
        while set_operator(ps) == op
            ps.i += 2
            (is(peek(ps), ']') || !more(ps)) && fail(ps, "invalid set operation in character class")
            operand, operand_range = class_set_element!(ps)
            operand_range && fail(ps, "invalid set operation in character class")
            charge!(ps, RANGE_SIZE * (length(value.set.ranges) + length(operand.set.ranges)) ÷ 2)
            value = is(op, '&') ? intersect(value, operand) : subtract(value, operand)
        end
        is(peek(ps), ']') || fail(ps, "invalid set operation in character class")
        return value
    end
    # A union.
    while more(ps) && !is(peek(ps), ']')
        set_operator(ps) != 0 && fail(ps, "invalid set operation in character class")
        operand, _ = class_set_element!(ps)
        charge!(ps, RANGE_SIZE * (length(value.set.ranges) + length(operand.set.ranges)) ÷ 2)
        value = union(value, operand)
    end
    return value
end

"The set operator at the position (& for &&, - for --), or 0."
function set_operator(ps::Parser)
    if ps.i + 1 < length(ps.p) && at(ps, ps.i) == at(ps, ps.i + 1) && (is(at(ps, ps.i), '&') || is(at(ps, ps.i), '-'))
        return at(ps, ps.i)
    end
    return 0
end

"""
Reads one element of a class of the v flag's grammar: an operand, or a range of two characters, which it reports.
"""
function class_set_element!(ps::Parser)
    charge!(ps, NODE_SIZE)
    c = peek(ps)
    if is(c, '[')
        # A nested class: its strings count as strings whether or not there are any.
        start = ps.i
        ps.depth += 1
        ps.depth > MAX_NESTING && throw(TooLargeError(LIMIT_NESTING, MAX_NESTING))
        ps.i += 1
        negated = eat!(ps, '^')
        inner = class_set_contents!(ps)
        eat!(ps, ']') || fail(ps, "unterminated character class")
        ps.depth -= 1
        if negated
            if inner.may_contain_strings
                ps.i = start
                fail(ps, "negated character class may contain strings")
            end
            return class_set_value_of(complement(inner.set)), false
        end
        return inner, false
    end
    if is(c, '\\')
        ps.i + 1 >= length(ps.p) && fail(ps, "\\ at end of pattern")
        e = at(ps, ps.i + 1)
        if is(e, 'q')
            ps.i += 2
            return class_string_disjunction!(ps), false
        end
        ps.i += 1
        set = class_escape!(ps, e)
        if set !== nothing
            strs = ps.escape_strings
            strs === nothing || return strings_value(ps, fold_if!(ps, set), strs), false
            # A class escape is folded as one operand; \P is already the complement of a folded set.
            is(e, 'P') || (set = fold_if!(ps, set))
            return class_set_value_of(set), false
        end
        ps.i -= 1
    end
    first = class_set_character!(ps)
    if is(peek(ps), '-') && set_operator(ps) == 0
        dash = ps.i
        ps.i += 1
        next = peek(ps)
        escape_class = is(next, '\\') && ps.i + 1 < length(ps.p) && in_ascii(at(ps, ps.i + 1), "qdDwWsSpP")
        if is(next, ']') || is(next, '[') || escape_class
            ps.i = dash
            fail(ps, "invalid character class range")
        end
        second = class_set_character!(ps)
        if second < first
            ps.i = dash
            fail(ps, "range out of order in character class")
        end
        return class_set_value_of(fold_if!(ps, CharSet(Int[first, second]))), true
    end
    return class_set_value_of(fold_if!(ps, CharSet(Int[first, first]))), false
end

"""
Reads one character of a class of the v flag's grammar: a character that is not a syntax character and does not
begin a reserved double punctuator, or an escape, which may be of a reserved punctuator.
"""
function class_set_character!(ps::Parser)
    more(ps) || fail(ps, "unterminated character class")
    c = at(ps, ps.i)
    if is(c, '\\')
        ps.i + 1 >= length(ps.p) && fail(ps, "\\ at end of pattern")
        e = at(ps, ps.i + 1)
        if is(e, 'b')
            ps.i += 2
            return 0x08 % Int
        end
        if in_ascii(e, "&-!#%,:;<=>@`~")
            ps.i += 2
            return e
        end
        ps.i += 1
        return character_escape!(ps, true)
    end
    in_ascii(c, raw"()[]{}/-\|") && fail(ps, "invalid character in character class")
    if ps.i + 1 < length(ps.p) && at(ps, ps.i + 1) == c && in_ascii(c, "&!#\$%*+,.:;<=>?@^`~")
        fail(ps, "invalid set operation in character class")
    end
    ps.i += 1
    return c
end

"Reads the strings of \\q{...} after its \\q. A string of one character is a character of the class."
function class_string_disjunction!(ps::Parser)
    eat!(ps, '{') || fail(ps, "invalid escape")
    current = Int[]
    value = empty_class_set_value()
    while true
        more(ps) || fail(ps, "unterminated character class")
        c = peek(ps)
        if is(c, '|') || is(c, '}')
            ps.i += 1
            if length(current) == 1
                set = fold_if!(ps, CharSet(Int[current[1], current[1]]))
                value = ClassSetValue(union(value.set, set), value.strings, value.may_contain_strings)
            else
                charge!(ps, NODE_SIZE * max(length(current), 1))
                s = canonical_string(ps, current)
                strs = value.strings
                s in strs || push!(strs, s)
                value = ClassSetValue(value.set, strs, true)
            end
            empty!(current)
            is(c, '}') && break
            continue
        end
        push!(current, class_set_character!(ps))
    end
    return value
end

"""
The value of a property of strings: its code points, and its sequences (case folded in a case-insensitive group).
"""
strings_value(ps::Parser, set::CharSet, strs::Vector{Vector{Int}}) =
    ClassSetValue(set, [canonical_string(ps, s) for s in strs], true)

"""
A string as its code points, each canonicalized in a case-insensitive group so that strings are compared as ECMA-262
compares them.
"""
canonical_string(ps::Parser, code_points::Vector{Int}) = [ps.icase ? canonicalize(c, true) : c for c in code_points]

"""
The node of a class of the v flag's grammar: its set, or, where it holds strings, the alternatives of its strings
longest first and then its set, as ECMA-262 orders them, in a group.
"""
function class_node(ps::Parser, value::ClassSetValue, negated::Bool)
    negated && return set_node(complement(value.set))
    isempty(value.strings) && return set_node(value.set)
    ordered = sort(value.strings, by=length, rev=true, alg=Base.Sort.DEFAULT_STABLE)
    alternatives = Node[]
    for s in ordered
        charge!(ps, NODE_SIZE * (length(s) + 1))
        if isempty(s)
            push!(alternatives, Node(N_EMPTY))
            continue
        end
        push!(alternatives, with_subs(N_CAT, [char_node_of(ps, c) for c in s]...))
    end
    isempty(value.set.ranges) || push!(alternatives, set_node(value.set))
    return with_subs(N_GROUP, with_subs(N_ALT, alternatives...))
end
