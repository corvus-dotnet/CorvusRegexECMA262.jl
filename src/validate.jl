# Whether a pattern is valid in the grammar, decided as the parser decides it but without its limits of size, and with
# nothing allocated for any pattern of ordinary size: no tree, no sets, no string (the design of the .NET engine's
# EcmaRegexValidator, and of validate.rs of the Rust crate, which is validate.go).
#
# It reads the pattern where it lies, decoding a character only where the grammar needs it. It keeps the groups and the
# nested classes of the v flag on stacks of its own rather than recursing, so that no pattern can overflow the stack,
# and it keeps a group name as its place in the pattern and looks a property name up as a view of it. A named group is
# kept as the disjunction and the alternative it lies in, never a copy of the path to it, so the memory is in
# proportion to the pattern however deeply named groups nest. A validator is
# taken from a pool and given back, as the state of a match is, so its stacks grow to what the patterns it reads need
# and are kept for the next. It asks the grammar only: the parser's limits of size (the length of the pattern, the
# nesting of groups, the size it counts) belong to compiling a pattern, and none of them applies here.
#
# Each function follows the function of the parser with the same name, and makes the same decision at each step. A
# position is twice the index (from 0) of a byte of the pattern, plus one for the second half of a character beyond the
# Basic Multilingual Plane when it is read as two UTF-16 code units (without the u flag the grammar reads code units).

# A character escape that is not valid.
const INVALID_ESCAPE = -2

const KIND_GROUP = 0
const KIND_LOOKAHEAD = 1
const KIND_LOOKBEHIND = 2

# A frame of a class of the v flag: whether it is negated, its phase, its operator, whether it may contain strings.
const CLASS_FRAME = 4
# The entries of a disjunction in disjunction_table.
const DISJUNCTION_FRAME = 4
const PHASE_START = 0
const PHASE_UNION = 1
const PHASE_OPERANDS = 2
const WAITING_FIRST = 3
const WAITING_UNION = 4
const WAITING_OPERAND = 5

# What a class escape was.
const ESCAPE_NONE = 0
const ESCAPE_INVALID = 1
const ESCAPE_VALID = 2
const ESCAPE_STRINGS = 3

# One element of a class of the v flag's grammar: not valid, a nested class (whose frame is now open), or an operand.
const ELEMENT_INVALID = 0
const ELEMENT_NESTED = 1
const ELEMENT_OPERAND = 2

# The stacks and the table of names a validator keeps between patterns, up to these sizes.
const MAX_RETAINED_VALIDATOR_STACK = 4096
const MAX_RETAINED_NAME_TABLE = 1024

mutable struct Validator
    s::String
    end_::Int
    unicode::Bool
    sets::Bool
    es2020::Bool
    ucd::UCD.Ucd
    id_start::UCD.Table
    id_continue::UCD.Table

    i::Int
    has_names::Bool
    group_count::Int
    disjunctions::Int
    # The disjunctions open at the position, outermost first (the parser's path, whose alternatives are in
    # disjunction_table).
    path::Vector{Int}
    # The groups open at the position: the kind of each.
    frames::Vector{Int}
    # Each named group: the start and the end of its name, the disjunction and the alternative it lies directly in, and
    # the hash of its name.
    names::Vector{Int}
    # Each disjunction, by its number from 1, as DISJUNCTION_FRAME entries: the disjunction it lies in (0 for the
    # pattern's own) and the alternative of that one it lies in, its own current alternative, and whether it is still
    # open. A closed disjunction's first two entries may be moved on to an ancestor (see separate_alternatives).
    disjunction_table::Vector{Int}
    # The places of the named groups by the hash of their names: one more than the place in names (from 0) of the last
    # group with each name (0 for none). Open addressing, a power of two long and at most half full.
    name_table::Vector{Int}
    distinct_names::Int
    # Each named reference: the start and the end of its name.
    references::Vector{Int}
    # The classes of the v flag open at the position (see CLASS_FRAME).
    classes::Vector{Int}

    # What the last group name, class atom or class element read was, beside its result.
    name_start::Int
    name_stop::Int
    atom_was_set::Bool
    element_strings::Bool
    element_range::Bool
end

Validator() = Validator("", 0, false, false, false, UCD.V17, UCD.Table(UInt16[], UInt32[]), UCD.Table(UInt16[], UInt32[]),
    0, false, 0, 0, Int[], Int[], Int[], Int[], zeros(Int, 32), 0, Int[], Int[], 0, 0, false, false, false)

# The tables a group name is read with in each version (the parser's id_start and id_continue), read once: a table
# looked up for each pattern would be boxed.
const ID_TABLES_13 = (UCD.V13.binary_tables["ID_Start"], UCD.V13.binary_tables["ID_Continue"])
const ID_TABLES_17 = (UCD.V17.binary_tables["ID_Start"], UCD.V17.binary_tables["ID_Continue"])
const ID_TABLES_18 = (UCD.V18.binary_tables["ID_Start"], UCD.V18.binary_tables["ID_Continue"])

# The validators not in use. A task takes one for a pattern and gives it back.
const VALIDATORS = Validator[]
const VALIDATORS_LOCK = Threads.SpinLock()

function take_validator()
    lock(VALIDATORS_LOCK)
    v = isempty(VALIDATORS) ? nothing : pop!(VALIDATORS)
    unlock(VALIDATORS_LOCK)
    return v === nothing ? Validator() : v
end

function give_validator(v::Validator)
    # No stack is longer than the pattern, so one read from a long pattern is not kept.
    if ncodeunits(v.s) > MAX_RETAINED_VALIDATOR_STACK
        v.path, v.frames, v.names, v.disjunction_table, v.references, v.classes = Int[], Int[], Int[], Int[], Int[], Int[]
    else
        for stack in (v.path, v.frames, v.names, v.disjunction_table, v.references, v.classes)
            empty!(stack)
        end
    end
    v.s = ""
    if length(v.name_table) > MAX_RETAINED_NAME_TABLE
        v.name_table = zeros(Int, 32)
    elseif v.distinct_names != 0
        fill!(v.name_table, 0)
    end
    v.distinct_names = 0
    lock(VALIDATORS_LOCK)
    push!(VALIDATORS, v)
    unlock(VALIDATORS_LOCK)
end

"""
Whether a pattern of valid UTF-8 is valid in the grammar of the u and v flags (with `sets`, `unicode` is set too), of
an edition and under the version of Unicode of the major number.
"""
function validate_pattern(pattern::String, unicode::Bool, sets::Bool, es2020::Bool, major::Int)
    v = take_validator()
    v.s = pattern
    v.end_ = 2 * ncodeunits(pattern)
    v.unicode = unicode
    v.sets = sets
    v.es2020 = es2020
    v.ucd = UCD.by_major(major)
    v.id_start, v.id_continue = major == 13 ? ID_TABLES_13 : major == 18 ? ID_TABLES_18 : ID_TABLES_17
    v.i = 0
    v.has_names = false
    v.group_count = 0
    v.disjunctions = 0
    try
        return validate!(v)
    finally
        give_validator(v)
    end
end

is_one_of(c::Int, set::String) = 0 <= c < 128 && occursin(Char(c), set)

# The byte at a position (from 0).
@inline byte_at(v::Validator, b::Int) = codeunit(v.s, b + 1)

"""
The element at a position (a code point with the u flag's grammar, a UTF-16 code unit without), and the position after
it.
"""
function at(v::Validator, pos::Int)
    b = pos >> 1
    c = v.s[b+1]
    r = Int(codepoint(c))
    width = ncodeunits(c)
    if r > 0xFFFF && !v.unicode
        # Two code units: the high surrogate, then the low one.
        pos & 1 == 0 && return high_surrogate(r), pos | 1
        return low_surrogate(r), (b + width) << 1
    end
    return r, (b + width) << 1
end

more(v::Validator) = v.i < v.end_
peek(v::Validator) = v.i < v.end_ ? at(v, v.i)[1] : -1

# The element after the one at the position, or -1.
function peek_second(v::Validator)
    v.i >= v.end_ && return -1
    _, next = at(v, v.i)
    return next < v.end_ ? at(v, next)[1] : -1
end

function next!(v::Validator)
    c, next = at(v, v.i)
    v.i = next
    return c
end

function eat!(v::Validator, c::Char)
    if v.i < v.end_
        e, next = at(v, v.i)
        if e == Int(c)
            v.i = next
            return true
        end
    end
    return false
end

function validate!(v::Validator)
    scan_groups!(v)
    push_disjunction!(v)
    while more(v)
        c = peek(v)
        if c == Int('|')
            next!(v)
            v.disjunction_table[frame(v.path[end])+3] += 1
            continue
        end
        if c == Int(')')
            # The end of a group: an unmatched ')' when none is open.
            isempty(v.frames) && return false
            next!(v)
            v.disjunction_table[frame(pop!(v.path))+4] = 0
            kind = pop!(v.frames)
            # Annex B lets a quantifier follow a lookahead. The u flag does not, and neither lets one follow a
            # lookbehind.
            quantifiable = kind == KIND_GROUP || (!v.unicode && kind == KIND_LOOKAHEAD)
            q = quantifier!(v)
            (q < 0 || (q > 0 && !quantifiable)) && return false
            continue
        end
        if c == Int('(')
            kind = group_or_look!(v)
            kind < 0 && return false
            push!(v.frames, kind)
            push_disjunction!(v)
            continue
        end
        t = term!(v, c)
        t < 0 && return false
        q = quantifier!(v)
        (q < 0 || (q > 0 && t == 0)) && return false
    end
    # An unterminated group.
    isempty(v.frames) || return false
    # Every named reference names a group somewhere in the pattern.
    for r in 1:2:length(v.references)
        start, stop = v.references[r], v.references[r+1]
        v.name_table[find_name(v, start, stop, name_hash(v, start, stop))] == 0 && return false
    end
    return true
end

function push_disjunction!(v::Validator)
    up = isempty(v.path) ? 0 : v.path[end]
    push!(v.disjunction_table, up, up == 0 ? 0 : v.disjunction_table[frame(up)+3], 0, 1)
    v.disjunctions += 1
    push!(v.path, v.disjunctions)
end

# The place (from 0) in disjunction_table of a disjunction's entries.
frame(disjunction::Int) = (disjunction - 1) * DISJUNCTION_FRAME

# Counts the capturing groups of the pattern and notes whether any is named.
function scan_groups!(v::Validator)
    in_class = false
    pos = 0
    while pos < v.end_
        c, next = at(v, pos)
        if c == Int('\\')
            if next < v.end_
                _, next = at(v, next)
            end
        elseif c == Int('[')
            in_class = true
        elseif c == Int(']')
            in_class = false
        elseif c == Int('(') && !in_class
            e1, after1 = next < v.end_ ? at(v, next) : (-1, v.end_)
            if e1 != Int('?')
                v.group_count += 1
            else
                e2, after2 = after1 < v.end_ ? at(v, after1) : (-1, v.end_)
                e3 = e2 >= 0 && after2 < v.end_ ? at(v, after2)[1] : -1
                if e2 == Int('<') && e3 >= 0 && e3 != Int('=') && e3 != Int('!')
                    v.group_count += 1
                    v.has_names = true
                end
            end
        end
        pos = next
    end
end

# Reads a term that is not a group: 1 when a quantifier may follow it, 0 when one may not, -1 when it is not valid.
function term!(v::Validator, c::Int)
    if c == Int('^') || c == Int('$')
        next!(v)
        return 0
    elseif c == Int('[')
        return (v.sets ? class_set_expression!(v) : class!(v)) ? 1 : -1
    elseif c == Int('\\')
        return atom_escape!(v)
    elseif c == Int('*') || c == Int('+') || c == Int('?')
        return -1
    elseif c == Int('{')
        (v.unicode || looks_like_quantifier(v)) && return -1
    elseif c == Int(']') || c == Int('}')
        v.unicode && return -1
    end
    next!(v)
    return 1
end

# Whether the text at the current '{' reads as {n}, {n,} or {n,m}.
function looks_like_quantifier(v::Validator)
    _, k = at(v, v.i)
    start = k
    while k < v.end_
        c, next = at(v, k)
        is_digit(c) || break
        k = next
    end
    (k == start || k >= v.end_) && return false
    c, after_digits = at(v, k)
    c == Int('}') && return true
    c == Int(',') || return false
    k = after_digits
    while k < v.end_
        c, next = at(v, k)
        is_digit(c) || break
        k = next
    end
    k >= v.end_ && return false
    return at(v, k)[1] == Int('}')
end


"""
Whether the first of two runs of decimal digits (by position) is the greater number, whatever their lengths. A digit is
one byte, so two positions.
"""
function greater_as_written(v::Validator, a::Int, a_end::Int, b::Int, b_end::Int)
    while a < a_end && byte_at(v, a >> 1) == UInt8('0')
        a += 2
    end
    while b < b_end && byte_at(v, b >> 1) == UInt8('0')
        b += 2
    end
    (a_end - a) != (b_end - b) && return a_end - a > b_end - b
    while a < a_end
        x, y = byte_at(v, a >> 1), byte_at(v, b >> 1)
        x != y && return x > y
        a += 2
        b += 2
    end
    return false
end

# Reads a run of decimal digits.
function skip_number!(v::Validator)
    while more(v) && is_digit(peek(v))
        next!(v)
    end
end

# Reads the decimal digits at the position, saturating as the parser's number does.
function number_value!(v::Validator)
    n = 0
    while more(v) && is_digit(peek(v))
        n = min(n * 10 + (next!(v) - Int('0')), MAX_COUNT)
    end
    return n
end

# Reads a quantifier when one is here: 0 for none, 1 for one, -1 when it is not valid.
function quantifier!(v::Validator)
    c = peek(v)
    if c == Int('*') || c == Int('+') || c == Int('?')
        next!(v)
    elseif c == Int('{') && looks_like_quantifier(v)
        next!(v)
        first = v.i
        skip_number!(v)
        first_end = v.i
        if eat!(v, ',') && peek(v) != Int('}')
            # The counts are compared as the numbers written, which can be past what a count is kept as.
            second = v.i
            skip_number!(v)
            greater_as_written(v, first, first_end, second, v.i) && return -1
        end
        eat!(v, '}') || return -1
    else
        return 0
    end
    eat!(v, '?')
    return 1
end

# Reads the start of a group or a lookaround, to its body: its kind, or -1 when it is not valid.
function group_or_look!(v::Validator)
    next!(v)
    (!eat!(v, '?') || eat!(v, ':')) && return KIND_GROUP
    c = peek(v)
    # Modifier groups came in ECMAScript 2025, so the 2020 grammar reads (?i as an invalid group.
    if (c == Int('i') || c == Int('m') || c == Int('s') || c == Int('-')) && !v.es2020
        return modifier_group!(v) ? KIND_GROUP : -1
    end
    (eat!(v, '=') || eat!(v, '!')) && return KIND_LOOKAHEAD
    eat!(v, '<') || return -1
    (eat!(v, '=') || eat!(v, '!')) && return KIND_LOOKBEHIND
    group_name!(v) || return -1
    start, stop = v.name_start, v.name_stop
    # Two groups may share a name only when they are in separate alternatives of one disjunction, so that no match can
    # go through both. The 2020 grammar refuses a name used twice, wherever the groups are. The last group with the name
    # is the only one to ask: the groups before it lie in alternatives apart from it, of a disjunction this group is
    # either outside, where its alternatives are all one to this group, or inside, in an alternative after theirs.
    hash = name_hash(v, start, stop)
    slot = find_name(v, start, stop, hash)
    found = v.name_table[slot] != 0
    if found
        last = v.name_table[slot] - 1
        (v.es2020 || !separate_alternatives(v, v.names[last+3], v.names[last+4])) && return -1
    end
    entry = length(v.names)
    disjunction = v.path[end]
    push!(v.names, start, stop, disjunction, v.disjunction_table[frame(disjunction)+3], hash)
    if found
        v.name_table[slot] = entry + 1
    else
        add_name!(v, slot, entry)
    end
    return KIND_GROUP
end

"""
Whether a named group, by the disjunction and the alternative it lies directly in, and the current position lie in
different alternatives of some disjunction: of the innermost disjunction around the group that is still open, which is
the innermost around both. A disjunction never opens again once closed, so the walk out of closed ones moves each one it
passes on to its grandparent, and the walks take time in proportion to the pattern in all.
"""
function separate_alternatives(v::Validator, disjunction::Int, alternative::Int)
    t = v.disjunction_table
    while t[frame(disjunction)+4] == 0
        at = frame(disjunction)
        up = frame(t[at+1])
        if t[up+4] == 0
            t[at+1], t[at+2] = t[up+1], t[up+2]
        end
        alternative, disjunction = t[at+2], t[at+1]
    end
    return t[frame(disjunction)+3] != alternative
end

# Reads the modifiers of a group such as (?i:...) or (?s-i:...), after the "(?", to its ':'.
function modifier_group!(v::Validator)
    seen, removing = 0, false
    while !eat!(v, ':')
        c = peek(v)
        if c == Int('-')
            removing && return false
            next!(v)
            removing = true
            continue
        end
        flag = c == Int('i') ? 1 : c == Int('m') ? 2 : c == Int('s') ? 4 : 0
        (flag == 0 || seen & flag != 0) && return false
        next!(v)
        seen |= flag
    end
    return seen != 0
end

"""
Reads a group name up to and including its '>', and keeps the positions of its first character and of the '>' in
name_start and name_stop. A character of the name may be written as a Unicode escape.
"""
function group_name!(v::Validator)
    start = v.i
    count = 0
    while true
        if peek(v) == Int('>')
            v.name_start, v.name_stop = start, v.i
            next!(v)
            return count != 0
        end
        more(v) || return false
        c = name_character!(v)
        c < 0 && return false
        ok = count == 0 ? (c == Int('$') || c == Int('_') || UCD.contains(v.id_start, c)) :
             (c == Int('$') || c == 0x200C || c == 0x200D || UCD.contains(v.id_continue, c))
        ok || return false
        count += 1
    end
end

# Reads one character of a group name: a code point, written or as a Unicode escape, or -1.
function name_character!(v::Validator)
    c = next!(v)
    if c == Int('\\')
        eat!(v, 'u') || return -1
        return unicode_escape!(v, true)
    end
    if 0xD800 <= c <= 0xDBFF
        low = peek(v)
        if 0xDC00 <= low <= 0xDFFF
            # Without the u flag the pattern is code units, and a name still takes a surrogate pair as one character.
            next!(v)
            return 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00)
        end
    end
    return c
end

# The hash of a name, by the positions of its characters, over its code points.
function name_hash(v::Validator, start::Int, stop::Int)
    saved = v.i
    hash = UInt32(2166136261)
    v.i = start
    while v.i < stop
        hash = (hash ⊻ (name_character!(v) % UInt32)) * UInt32(16777619)
    end
    v.i = saved
    return Int(hash)
end

# The slot (from 1) of the name table that holds the last group with a name, or the empty slot the name would take.
function find_name(v::Validator, start::Int, stop::Int, hash::Int)
    mask = length(v.name_table) - 1
    slot = hash & mask
    while true
        held = v.name_table[slot+1]
        held == 0 && return slot + 1
        n = held - 1
        v.names[n+5] == hash && same_name(v, start, stop, v.names[n+1], v.names[n+2]) && return slot + 1
        slot = (slot + 1) & mask
    end
end

# Puts a new name's group in the empty slot found for it, and doubles the table when it is half full.
function add_name!(v::Validator, slot::Int, entry::Int)
    v.name_table[slot] = entry + 1
    v.distinct_names += 1
    v.distinct_names * 2 <= length(v.name_table) && return
    table = zeros(Int, 2 * length(v.name_table))
    mask = length(table) - 1
    for held in v.name_table
        held == 0 && continue
        k = v.names[held+4] & mask
        while table[k+1] != 0
            k = (k + 1) & mask
        end
        table[k+1] = held
    end
    v.name_table = table
end

# Whether two names, by the positions of their characters, are the same code points.
function same_name(v::Validator, a_start::Int, a_stop::Int, b_start::Int, b_stop::Int)
    saved = v.i
    a, b = a_start, b_start
    same = true
    while true
        a_done, b_done = a >= a_stop, b >= b_stop
        if a_done || b_done
            same = a_done && b_done
            break
        end
        v.i = a
        ca = name_character!(v)
        a = v.i
        v.i = b
        cb = name_character!(v)
        b = v.i
        if ca != cb
            same = false
            break
        end
    end
    v.i = saved
    return same
end

# Reads an escape outside a class: 1 when a quantifier may follow it, 0 when one may not, -1 when it is not valid.
function atom_escape!(v::Validator)
    next!(v)
    more(v) || return -1
    c = peek(v)
    if c == Int('b') || c == Int('B')
        next!(v)
        return 0
    end
    if c == Int('k')
        next!(v)
        # Annex B reads \k as the letter k in a pattern with no named group.
        !v.unicode && !v.has_names && return 1
        (eat!(v, '<') && group_name!(v)) || return -1
        push!(v.references, v.name_start, v.name_stop)
        return 1
    end
    if Int('1') <= c <= Int('9')
        start = v.i
        number_value!(v) <= v.group_count && return 1
        v.unicode && return -1
        # Annex B reads it as an octal escape, or as the digit itself.
        v.i = start
        legacy_octal!(v)
        return 1
    end
    e = class_escape!(v, c)
    (e == ESCAPE_VALID || e == ESCAPE_STRINGS) && return 1
    e == ESCAPE_INVALID && return -1
    return character_escape!(v, false) != INVALID_ESCAPE ? 1 : -1
end

"""
Reads an Annex B octal escape of up to three digits with a value below 256. A digit that cannot start one (8 or 9)
stands for itself.
"""
function legacy_octal!(v::Validator)
    n, k = 0, 0
    while k < 3 && more(v) && Int('0') <= peek(v) <= Int('7') && n * 8 + (peek(v) - Int('0')) <= 0o377
        n = n * 8 + (next!(v) - Int('0'))
        k += 1
    end
    return k == 0 ? next!(v) : n
end

# Reads a class escape such as \d or \p{...} whose letter is c. It reads nothing when c does not start one.
function class_escape!(v::Validator, c::Int)
    if c in (Int('d'), Int('D'), Int('w'), Int('W'), Int('s'), Int('S'))
        next!(v)
        return ESCAPE_VALID
    end
    (c == Int('p') || c == Int('P')) || return ESCAPE_NONE
    # Without the u flag \p is the letter p.
    v.unicode || return ESCAPE_NONE
    next!(v)
    eat!(v, '{') || return ESCAPE_INVALID
    start = v.i
    while more(v) && peek(v) != Int('}')
        next!(v)
    end
    stop = v.i
    eat!(v, '}') || return ESCAPE_INVALID
    # A name ECMA-262 defines is ASCII, so an expression with any other character names nothing.
    for b in (start>>1):(stop>>1)-1
        byte_at(v, b) >= 0x80 && return ESCAPE_INVALID
    end
    expr = SubString(v.s, (start >> 1) + 1, stop >> 1)
    # The 2020 grammar knows only the names and values of its own tables, whatever the version of Unicode.
    found = (!v.es2020 || es2020_names_property(expr)) && names_property(v.ucd, expr)
    if !found && v.sets && c == Int('p') && names_string_property(v.ucd, expr)
        # A property of strings, which the v flag alone names, and which has no complement.
        return ESCAPE_STRINGS
    end
    return found ? ESCAPE_VALID : ESCAPE_INVALID
end

"""
Whether an expression of ASCII between the braces of \\p{...} names a property under a version of Unicode, as
property_set finds one, without building its set or a string.
"""
function names_property(u::UCD.Ucd, expr::SubString{String})
    eq = findfirst('=', expr)
    if eq !== nothing
        name, value = SubString(expr, 1, eq - 1), SubString(expr, eq + 1)
        (name == "General_Category" || name == "gc") && return names_category(u, value)
        (name == "Script" || name == "sc") && return names_script(value) || haskey(u.script_tables, value)
        (name == "Script_Extensions" || name == "scx") &&
            return names_script(value) || haskey(u.script_extensions_tables, value)
        return false
    end
    names_category(u, expr) && return true
    canonical = binary_name(expr)
    canonical == "" && return false
    return canonical in ("ASCII", "Any", "Assigned") || haskey(u.binary_tables, canonical)
end

function names_category(u::UCD.Ucd, value::SubString{String})
    name = category_name(value)
    return name != "" && (haskey(UCD.GROUPS, name) || haskey(u.category_tables, name))
end

# The scripts whose sets are made, not generated: Unknown, and Katakana_Or_Hiragana, which is empty.
names_script(value::SubString{String}) = value in ("Unknown", "Zzzz", "Katakana_Or_Hiragana", "Hrkt")

# es2020_has_property over a view of the pattern.
function es2020_names_property(expr::SubString{String})
    eq = findfirst('=', expr)
    eq === nothing && return expr in ES2020_CATEGORY || expr in ES2020_BINARY
    name, value = SubString(expr, 1, eq - 1), SubString(expr, eq + 1)
    (name == "General_Category" || name == "gc") && return value in ES2020_CATEGORY
    return name in ES2020_NON_BINARY && value in ES2020_SCRIPT
end

# Whether the expression names a property of strings (string_property_of).
function names_string_property(u::UCD.Ucd, expr::SubString{String})
    expr == "RGI_Emoji" && return true
    for row in u.strings
        row[1] == expr && return true
    end
    return false
end

# Reads exactly n hexadecimal digits. It returns -1, reading nothing, when they are not there.
function hex!(v::Validator, n::Int)
    pos = v.i
    value = 0
    for _ in 1:n
        pos >= v.end_ && return -1
        c, next = at(v, pos)
        d = hex_value(c)
        d < 0 && return -1
        value = value * 16 + d
        pos = next
    end
    v.i = pos
    return value
end

# Reads the escape after a backslash, in or out of a class: the character it names, or INVALID_ESCAPE.
function character_escape!(v::Validator, in_class::Bool)
    at_ = v.i
    c = next!(v)
    c == Int('f') && return 0x0C
    c == Int('n') && return 0x0A
    c == Int('r') && return 0x0D
    c == Int('t') && return 0x09
    c == Int('v') && return 0x0B
    if c == Int('c')
        l = peek(v)
        if Int('a') <= l <= Int('z') || Int('A') <= l <= Int('Z')
            next!(v)
            return l % 32
        end
        if !v.unicode && in_class && (is_digit(l) || l == Int('_'))
            next!(v)
            return l % 32
        end
        v.unicode && return INVALID_ESCAPE
        # Annex B reads a \c that is not a control escape as a backslash followed by the letter c.
        v.i = at_
        return Int('\\')
    end
    if c == Int('0')
        if more(v) && is_digit(peek(v))
            v.unicode && return INVALID_ESCAPE
            v.i = at_
            return legacy_octal!(v)
        end
        return 0
    end
    if c == Int('x')
        h = hex!(v, 2)
        h >= 0 && return h
        return v.unicode ? INVALID_ESCAPE : Int('x')
    end
    if c == Int('u')
        u = unicode_escape!(v, v.unicode)
        u >= 0 && return u
        return v.unicode ? INVALID_ESCAPE : Int('u')
    end
    if Int('1') <= c <= Int('9') && !v.unicode && in_class
        v.i = at_
        return legacy_octal!(v)
    end
    # Identity escapes. The u flag allows only the syntax characters and '/', and '-' in a class. Annex B allows any
    # character, but k in a pattern with a named group.
    if (v.unicode && !is_one_of(c, "^\$\\.*+?()[]{}|/") && !(in_class && c == Int('-'))) || (c == Int('k') && v.has_names)
        return INVALID_ESCAPE
    end
    return c
end

"""
Reads what follows the u of a Unicode escape and returns the character, or -1, reading nothing, when it is not a
well-formed escape. With unicode_mode, as with the u flag and always in a group name, it accepts the form with braces
and reads a surrogate pair written as two escapes as one code point.
"""
function unicode_escape!(v::Validator, unicode_mode::Bool)
    start = v.i
    if unicode_mode && eat!(v, '{')
        digits = v.i
        n = 0
        while more(v) && hex_value(peek(v)) >= 0
            n <= MAX_RUNE && (n = n * 16 + hex_value(peek(v)))
            next!(v)
        end
        if digits == v.i || !eat!(v, '}') || n > MAX_RUNE
            v.i = start
            return -1
        end
        return n
    end
    u = hex!(v, 4)
    u < 0 && return -1
    if unicode_mode && 0xD800 <= u <= 0xDBFF && peek(v) == Int('\\') && peek_second(v) == Int('u')
        save = v.i
        next!(v)
        next!(v)
        low = hex!(v, 4)
        0xDC00 <= low <= 0xDFFF && return 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00)
        v.i = save
    end
    return u
end

# Reads a character class from its '[' to its ']'.
function class!(v::Validator)
    next!(v)
    eat!(v, '^')
    while true
        more(v) || return false
        eat!(v, ']') && return true
        first = class_atom!(v)
        first_set = v.atom_was_set
        first == INVALID_ESCAPE && return false
        if peek(v) == Int('-') && peek_second(v) >= 0 && peek_second(v) != Int(']')
            next!(v)
            second = class_atom!(v)
            second_set = v.atom_was_set
            second == INVALID_ESCAPE && return false
            if first_set || second_set
                # Annex B reads the '-' as itself when a class escape is at either end.
                v.unicode && return false
                continue
            end
            second < first && return false
        end
    end
end

# Reads one member of a class: its character, or 0 for a class escape, or INVALID_ESCAPE. atom_was_set says whether it
# was a class escape.
function class_atom!(v::Validator)
    v.atom_was_set = false
    c = next!(v)
    c == Int('\\') || return c
    more(v) || return INVALID_ESCAPE
    e = peek(v)
    if e == Int('b')
        next!(v)
        return 0x08
    end
    k = class_escape!(v, e)
    if k == ESCAPE_VALID || k == ESCAPE_STRINGS
        v.atom_was_set = true
        return 0
    elseif k == ESCAPE_INVALID
        v.atom_was_set = true
        return INVALID_ESCAPE
    end
    return character_escape!(v, true)
end

# The v flag.

"""
Reads a class of the v flag's grammar from its '[' to its ']', with its nested classes on a stack of frames: a union of
elements, or the intersection or the difference of operands, which may not be mixed. A negated class may not hold
anything that may match a string.
"""
function class_set_expression!(v::Validator)
    open_class!(v)
    while true
        top = length(v.classes) - CLASS_FRAME
        phase = v.classes[top+2]
        if phase == PHASE_START
            if peek(v) == Int(']')
                v.classes[top+4] = 0
                closed = close_class!(v)
                closed != 0 && return closed > 0
                continue
            end
            element = class_set_element!(v)
            element == ELEMENT_INVALID && return false
            if element == ELEMENT_NESTED
                v.classes[top+2] = WAITING_FIRST
            elseif !first_operand!(v, top, v.element_strings, v.element_range)
                return false
            end
        elseif phase == PHASE_UNION
            if more(v) && peek(v) != Int(']')
                set_operator(v) != 0 && return false
                element = class_set_element!(v)
                element == ELEMENT_INVALID && return false
                if element == ELEMENT_NESTED
                    v.classes[top+2] = WAITING_UNION
                elseif v.element_strings
                    v.classes[top+4] = 1
                end
                continue
            end
            closed = close_class!(v)
            closed != 0 && return closed > 0
        elseif phase == PHASE_OPERANDS
            if set_operator(v) == v.classes[top+3]
                next!(v)
                next!(v)
                (peek(v) == Int(']') || !more(v)) && return false
                element = class_set_element!(v)
                (element == ELEMENT_INVALID || v.element_range) && return false
                if element == ELEMENT_NESTED
                    v.classes[top+2] = WAITING_OPERAND
                else
                    operand!(v, top, v.element_strings)
                end
                continue
            end
            peek(v) == Int(']') || return false
            closed = close_class!(v)
            closed != 0 && return closed > 0
        else
            # A nested class is open above this one; it is never the top while it waits.
            return false
        end
    end
end

function open_class!(v::Validator)
    next!(v)
    push!(v.classes, eat!(v, '^') ? 1 : 0, PHASE_START, 0, 0)
end

"""
Closes the class at the top at its ']', and gives what it may contain to the class it is nested in, if any: 1 when it
was the outermost, 0 when it was nested, -1 when it is not valid. `top` is the place of a frame from 0.
"""
function close_class!(v::Validator)
    eat!(v, ']') || return -1
    top = length(v.classes) - CLASS_FRAME
    negated, strs = v.classes[top+1] != 0, v.classes[top+4] != 0
    negated && strs && return -1
    resize!(v.classes, top)
    isempty(v.classes) && return 1
    # A nested class is an operand, never a range; a negated one may contain no strings.
    strs = strs && !negated
    parent = length(v.classes) - CLASS_FRAME
    phase = v.classes[parent+2]
    if phase == WAITING_FIRST
        return first_operand!(v, parent, strs, false) ? 0 : -1
    elseif phase == WAITING_UNION
        v.classes[parent+2] = PHASE_UNION
        strs && (v.classes[parent+4] = 1)
    else
        v.classes[parent+2] = PHASE_OPERANDS
        operand!(v, parent, strs)
    end
    return 0
end

# Takes the first element of a class, and decides from what follows it whether the class is a union or operations.
function first_operand!(v::Validator, top::Int, strs::Bool, range::Bool)
    v.classes[top+4] = strs ? 1 : 0
    op = set_operator(v)
    if op != 0
        # An intersection or a difference: operands only, with the one operator between every two.
        range && return false
        v.classes[top+2] = PHASE_OPERANDS
        v.classes[top+3] = op
        return true
    end
    v.classes[top+2] = PHASE_UNION
    return true
end

# Takes an operand of an intersection (strings only where both may hold them) or a difference (the first's).
function operand!(v::Validator, top::Int, strs::Bool)
    v.classes[top+3] == Int('&') && !strs && (v.classes[top+4] = 0)
end

# The set operator at the position ('&' for &&, '-' for --), or 0.
function set_operator(v::Validator)
    c = peek(v)
    return (c == Int('&') || c == Int('-')) && peek_second(v) == c ? c : 0
end

"""
Reads one element of a class of the v flag's grammar: what it is. element_strings says whether it may hold strings, and
element_range whether it is a range of two characters.
"""
function class_set_element!(v::Validator)
    v.element_strings = false
    v.element_range = false
    c = peek(v)
    if c == Int('[')
        open_class!(v)
        return ELEMENT_NESTED
    end
    if c == Int('\\')
        e = peek_second(v)
        e < 0 && return ELEMENT_INVALID
        if e == Int('q')
            next!(v)
            next!(v)
            return class_string_disjunction!(v) ? ELEMENT_OPERAND : ELEMENT_INVALID
        end
        save = v.i
        next!(v)
        k = class_escape!(v, e)
        k == ESCAPE_INVALID && return ELEMENT_INVALID
        k == ESCAPE_VALID && return ELEMENT_OPERAND
        if k == ESCAPE_STRINGS
            v.element_strings = true
            return ELEMENT_OPERAND
        end
        v.i = save
    end
    first = class_set_character!(v)
    first == INVALID_ESCAPE && return ELEMENT_INVALID
    if peek(v) == Int('-') && set_operator(v) == 0
        next!(v)
        p = peek(v)
        (p == Int(']') || p == Int('[') || (p == Int('\\') && is_one_of(peek_second(v), "qdDwWsSpP"))) &&
            return ELEMENT_INVALID
        second = class_set_character!(v)
        (second == INVALID_ESCAPE || second < first) && return ELEMENT_INVALID
        v.element_range = true
    end
    return ELEMENT_OPERAND
end

"""
Reads one character of a class of the v flag's grammar: a character that is not a syntax character and does not begin
a reserved double punctuator, or an escape, which may be of a reserved punctuator.
"""
function class_set_character!(v::Validator)
    more(v) || return INVALID_ESCAPE
    c = peek(v)
    if c == Int('\\')
        e = peek_second(v)
        e < 0 && return INVALID_ESCAPE
        if e == Int('b')
            next!(v)
            next!(v)
            return 0x08
        end
        if is_one_of(e, "&-!#%,:;<=>@`~")
            next!(v)
            next!(v)
            return e
        end
        next!(v)
        return character_escape!(v, true)
    end
    is_one_of(c, "()[]{}/-\\|") && return INVALID_ESCAPE
    peek_second(v) == c && is_one_of(c, "&!#\$%*+,.:;<=>?@^`~") && return INVALID_ESCAPE
    next!(v)
    return c
end

"""
Reads the strings of \\q{...} after its \\q: whether it is valid. element_strings says whether any string is of other
than one character.
"""
function class_string_disjunction!(v::Validator)
    eat!(v, '{') || return false
    count = 0
    while true
        more(v) || return false
        c = peek(v)
        if c == Int('|') || c == Int('}')
            next!(v)
            count != 1 && (v.element_strings = true)
            count = 0
            c == Int('}') && return true
            continue
        end
        class_set_character!(v) == INVALID_ESCAPE && return false
        count += 1
    end
end
