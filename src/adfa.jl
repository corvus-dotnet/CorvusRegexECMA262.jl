# An anchored, leftmost-first automaton over ASCII text, which finds where the match that starts at a position ends
# for a pattern that needs no backtracking (adfa.rs): what the regex crate's DFAs do for the match, taken into this
# engine where ECMA-262's semantics allow it.
#
# A state is an ordered list of the pattern's states (its threads, the most preferred first, as the backtracking matcher
# would try them), with whether the unit before it was a word character and whether it is at the start of the text.
# When the match state is among the threads, a match ends here, and the threads after it, which the backtracking matcher
# would only try had this way failed, are dropped; the threads before it may still find a longer match, which it would
# prefer. So the last match found before the threads run out is the backtracking matcher's match, for a pattern with no
# lookaround, no backreference and no repetition whose body can match the empty string (where ECMA-262's rule for an
# empty iteration would differ from a thread's). A unit beyond ASCII hands the start back to the backtracking matcher.
#
# Every state is worked out when the pattern is compiled, within bounds of states and steps, so that a pattern too large
# for an automaton costs little before that is known. This file builds the automata; the loops that read them over a
# text are in automata.jl. States are numbered from 0, as in the crate.

const ADFA_MAX_STATES = 2048
const ADFA_MAX_NFA = 1024
const ADFA_MAX_STEPS = 2_000_000
# The state with no thread left: no match can end further on.
const ADFA_DEAD = 0
# Flags a transition across which a match ends before the unit, and FAST_MATCHED the same in the premultiplied table.
const ADFA_MATCHED = 0x8000
const FAST_MATCHED = 0x8000_0000

# What find answers where no match starts, and where a unit beyond ASCII was reached first.
const ADFA_NONE = -1
const ADFA_BAIL = -2

# The kinds of what scan found.
const SCAN_MATCH = 0
const SCAN_IDLE = 1
const SCAN_BAIL = 2
const SCAN_NONE = 3

"The anchored automaton of a pattern."
struct AnchoredDfa
    # The class of each unit below 128, at index unit + 1.
    class_of::Vector{UInt8}
    shift::Int
    # fast[state * stride + class + 1] is the next state, premultiplied by the stride, with FAST_MATCHED when a match
    # ends before the unit.
    fast::Vector{UInt32}
    # For each state, whether a match ends at the end of the text.
    at_end::Vector{Bool}
    # The start state for each of: the unit before is a word character (bit 1), the start of the text (bit 0), at index
    # bits + 1.
    starts::NTuple{4,Int}
    # The start states differ (the pattern looks back at the unit before or at the start of the text).
    context::Bool
    # For the forward automaton (see build_forward_dfa), whether each state is a start state: no thread of an earlier
    # start is alive in it.
    start_like::Vector{Bool}
end

"""
The state after `prefix` from each start state, premultiplied by the stride (0 where no match can start with it), or
`nothing` when a match can end inside it or it holds a byte beyond ASCII: what find_after goes on from where a match is
known to start with `prefix`.
"""
function after(a::AnchoredDfa, prefix::Vector{UInt8})
    rows = zeros(UInt32, 4)
    for k in 1:4
        at = UInt32(a.starts[k]) << a.shift
        for b in prefix
            # No match from this start state begins with the prefix.
            at == 0 && break
            b >= 0x80 && return nothing
            t = a.fast[at+a.class_of[b+1]+1]
            t & FAST_MATCHED != 0 && return nothing
            at = t
        end
        rows[k] = at
    end
    return (rows[1], rows[2], rows[3], rows[4])
end

"""
The positions of a pattern read before a match can end: V8's Boyer-Moore lookahead (BoyerMooreLookahead in its regexp
compiler). For a window of positions lo..=hi of every match, the units each can be (table for ASCII, wide for any
other) are joined; a unit at hi from a place that is none of them rules out the starts from that place to hi - lo units
on, so the search reads one unit in hi - lo + 1 where the window's units are rare.
"""
struct SkipWin
    # The window's last position, the one read, and the starts one unit rules out, hi - lo + 1.
    hi::Int
    len::Int
    table::BitVector
    wide::Bool
end

"Whether the unit can be at some position of the window."
@inline hit(s::SkipWin, c::Integer) = c < 128 ? (@inbounds s.table[c+1]) : s.wide

"""
An automaton of the terms before the anchors of a search, read backwards (accepting where any of them can start): from
an occurrence of an anchor it finds, over ASCII text, every start from which some alternative's terms reach it. Only
terms with no assertion are taken.
"""
struct ReverseDfa
    class_of::Vector{UInt8}
    shift::Int
    # The transitions, each the next state's row (premultiplied by the stride, so 0 is the dead state) with
    # FAST_MATCHED where that state accepts.
    fast::Vector{UInt32}
    # The first state accepts (an empty run of terms).
    accept_first::Bool
end

# The kinds of the pattern's states.
const A_SET = 0x00
const A_SPLIT = 0x01
const A_BOL = 0x02
const A_EOL = 0x03
const A_WORD = 0x04
const A_NOT_WORD = 0x05
const A_MATCH = 0x06

"The states of a pattern, as parallel vectors that grow."
mutable struct AdfaNfa
    kind::Vector{UInt8}
    set0::Vector{UInt64}
    set1::Vector{UInt64}
    # The set holds a character beyond ASCII, which the automaton gives up at.
    wide::Vector{Bool}
    out::Vector{Int}
    alt::Vector{Int}
    failed::Bool
end

AdfaNfa() = AdfaNfa(UInt8[], UInt64[], UInt64[], Bool[], Int[], Int[], false)

function add!(b::AdfaNfa, k::UInt8, s0::UInt64, s1::UInt64, w::Bool, o::Int, a::Int)
    if length(b.kind) >= ADFA_MAX_NFA
        b.failed = true
        return 0
    end
    push!(b.kind, k)
    push!(b.set0, s0)
    push!(b.set1, s1)
    push!(b.wide, w)
    push!(b.out, o)
    push!(b.alt, a)
    return length(b.kind) - 1
end

add_to!(b::AdfaNfa, k::UInt8, o::Int) = add!(b, k, UInt64(0), UInt64(0), false, o, 0)

"Adds a split whose preferred way is first."
split!(b::AdfaNfa, first::Int, second::Int) = add!(b, A_SPLIT, UInt64(0), UInt64(0), false, first, second)

has(b::AdfaNfa, i::Int, c::Int) = c < 64 ? (b.set0[i+1] >> c) & 1 != 0 : (b.set1[i+1] >> (c - 64)) & 1 != 0

"Adds the states of a node that go on to `next`, and returns the state they start at."
function compile!(b::AdfaNfa, n::Node, next::Int)
    b.failed && return 0
    k = n.kind
    if k == N_EMPTY
        return next
    elseif k == N_CHAR
        s0 = 0 <= n.r < 64 ? UInt64(1) << n.r : UInt64(0)
        s1 = 64 <= n.r < 128 ? UInt64(1) << (n.r - 64) : UInt64(0)
        return add!(b, A_SET, s0, s1, n.r >= 128, next, 0)
    elseif k == N_SET
        r = n.set.ranges
        return add!(b, A_SET, n.set.ascii[1], n.set.ascii[2], !isempty(r) && r[end] >= 128, next, 0)
    elseif k == N_CAT
        for sub in Iterators.reverse(n.subs)
            next = compile!(b, sub, next)
        end
        return next
    elseif k == N_ALT
        start = compile!(b, n.subs[end], next)
        for j in length(n.subs)-1:-1:1
            o = compile!(b, n.subs[j], next)
            start = split!(b, o, start)
        end
        return start
    elseif k == N_GROUP
        return compile!(b, n.subs[1], next)
    elseif k == N_REPEAT
        sub = n.subs[1]
        if n.max != 0 && n.max != 1 && nullable(sub)
            # ECMA-262 refuses an empty iteration after the least count, which a thread does not know.
            b.failed = true
            return 0
        end
        if n.max == UNBOUNDED
            loop = split!(b, 0, 0)
            b.failed && return 0
            body = compile!(b, sub, loop)
            if n.lazy
                b.out[loop+1], b.alt[loop+1] = next, body
            else
                b.out[loop+1], b.alt[loop+1] = body, next
            end
            next = loop
        else
            i = n.min
            while i < n.max && !b.failed
                body = compile!(b, sub, next)
                next = n.lazy ? split!(b, next, body) : split!(b, body, next)
                i += 1
            end
        end
        i = 0
        while i < n.min && !b.failed
            next = compile!(b, sub, next)
            i += 1
        end
        return next
    elseif k == N_BOL
        return add_to!(b, A_BOL, next)
    elseif k == N_EOL
        return add_to!(b, A_EOL, next)
    elseif k == N_WORD_BOUNDARY && !n.fold
        return add_to!(b, A_WORD, next)
    elseif k == N_NOT_WORD_BOUNDARY && !n.fold
        return add_to!(b, A_NOT_WORD, next)
    end
    b.failed = true
    return 0
end

"Adds the states of a node read backwards that go on to `next`."
function compile_back!(b::AdfaNfa, n::Node, next::Int)
    b.failed && return 0
    k = n.kind
    if k == N_CAT
        for sub in n.subs
            next = compile_back!(b, sub, next)
        end
        return next
    elseif k == N_ALT
        start = compile_back!(b, n.subs[end], next)
        for j in length(n.subs)-1:-1:1
            o = compile_back!(b, n.subs[j], next)
            start = split!(b, o, start)
        end
        return start
    elseif k == N_GROUP
        return compile_back!(b, n.subs[1], next)
    elseif k == N_REPEAT
        sub = n.subs[1]
        if n.max == UNBOUNDED
            loop = split!(b, 0, 0)
            b.failed && return 0
            body = compile_back!(b, sub, loop)
            b.out[loop+1], b.alt[loop+1] = body, next
            next = loop
        else
            i = n.min
            while i < n.max && !b.failed
                body = compile_back!(b, sub, next)
                next = split!(b, body, next)
                i += 1
            end
        end
        i = 0
        while i < n.min && !b.failed
            next = compile_back!(b, sub, next)
            i += 1
        end
        return next
    elseif k == N_EMPTY || k == N_CHAR || k == N_SET
        return compile!(b, n, next)
    end
    b.failed = true
    return 0
end

"Makes the automaton's states from lists of the pattern's states."
mutable struct AdfaDet
    nfa::AdfaNfa
    mark::Vector{Int}
    generation::Int
    steps::Int
    stack::Vector{Int}
end

AdfaDet(nfa::AdfaNfa) = AdfaDet(nfa, zeros(Int, length(nfa.kind)), 0, ADFA_MAX_STEPS, Int[])

"""
Appends to `out`, in order of preference, the threads that reading nothing reaches from `from`, keeping the states that
read a unit, the anchors and boundaries still to pass, and the match, after which nothing more is kept. Boundaries are
passed or dropped with `words`, and kept to pass later without it.
"""
function closure!(d::AdfaDet, out::Vector{Int}, from::Vector{Int}, at_start::Bool, at_end::Bool, words::Bool,
    before::Bool, after::Bool)
    d.generation += 1
    return closure_on!(d, out, from, at_start, at_end, words, before, after)
end

"closure! after the closure just made, leaving out the states it reached."
function closure_on!(d::AdfaDet, out::Vector{Int}, from::Vector{Int}, at_start::Bool, at_end::Bool, words::Bool,
    before::Bool, after::Bool)
    empty!(d.stack)
    for k in length(from):-1:1
        push!(d.stack, from[k])
    end
    nfa = d.nfa
    while !isempty(d.stack)
        i = pop!(d.stack)
        d.steps -= 1
        d.mark[i+1] == d.generation && continue
        d.mark[i+1] = d.generation
        k = nfa.kind[i+1]
        if k == A_SPLIT
            push!(d.stack, nfa.alt[i+1], nfa.out[i+1])
        elseif k == A_BOL
            at_start && push!(d.stack, nfa.out[i+1])
        elseif k == A_EOL
            at_end ? push!(d.stack, nfa.out[i+1]) : push!(out, i)
        elseif k == A_WORD || k == A_NOT_WORD
            if !words
                push!(out, i)
            elseif (before != after) == (k == A_WORD)
                push!(d.stack, nfa.out[i+1])
            end
        elseif k == A_MATCH
            push!(out, i)
            return out
        else
            push!(out, i)
        end
    end
    return out
end

has_kind(d::AdfaDet, set::Vector{Int}, k::UInt8) = any(i -> d.nfa.kind[i+1] == k, set)

# The most positions looked at for a window.
const SKIP_POSITIONS = 16

"How often a unit is found in text, roughly: what a window's worth is reckoned by."
function unit_frequency(c::Int)
    c == Int(' ') && return 0.15
    Int('a') <= c <= Int('z') && return 0.06
    c in (Int('\n'), Int('\r'), Int('.'), Int(',')) && return 0.015
    (Int('A') <= c <= Int('Z') || Int('0') <= c <= Int('9')) && return 0.004
    return 0.003
end

"""
The states each depth's threads are at for skip_window, assertions taken as passed (they only rule threads out), or
`nothing` where a match can end, so that no later position is known.
"""
function skip_closure(nfa::AdfaNfa, from::Vector{Int})
    seen = falses(length(nfa.kind))
    stack = copy(from)
    sets = Int[]
    while !isempty(stack)
        i = pop!(stack)
        seen[i+1] && continue
        seen[i+1] = true
        k = nfa.kind[i+1]
        if k == A_MATCH
            return nothing
        elseif k == A_SET
            push!(sets, i)
        elseif k == A_SPLIT
            push!(stack, nfa.out[i+1], nfa.alt[i+1])
        else
            push!(stack, nfa.out[i+1])
        end
    end
    return sets
end

"""
The window of a tree (after simplify) worth reading one unit of instead of every unit, or `nothing`: the units each
position before a match can end can be, from the pattern's automaton without its determinisation, and the window whose
units are rare enough that one unit read passes over three starts or more, reckoned by unit_frequency.
"""
function skip_window(root::Node)
    b = AdfaNfa()
    match = add_to!(b, A_MATCH, 0)
    start = compile!(b, root, match)
    b.failed && return nothing
    tables = BitVector[]
    wides = Bool[]
    threads = [start]
    while length(tables) < SKIP_POSITIONS
        sets = skip_closure(b, threads)
        sets === nothing && break
        table = falses(128)
        wide = false
        for i in sets
            for c in 0:127
                table[c+1] = table[c+1] || has(b, i, c)
            end
            wide = wide || b.wide[i+1]
        end
        push!(tables, table)
        push!(wides, wide)
        # A character beyond ASCII takes more than one unit of UTF-8: the positions after it are not known.
        wide && break
        threads = [b.out[i+1] for i in sets]
    end
    best_worth, best_lo, best_hi = 0.0, -1, -1
    for lo in 0:length(tables)-1
        table = falses(128)
        wide = false
        for hi in lo:length(tables)-1
            table .|= tables[hi+1]
            wide = wide || wides[hi+1]
            p = wide ? 0.1 : 0.0
            for c in 0:127
                table[c+1] && (p += unit_frequency(c))
            end
            worth = (hi - lo + 1) * (1.0 - min(p, 1.0))
            if worth >= 3.0 && (best_lo < 0 || worth > best_worth)
                best_worth, best_lo, best_hi = worth, lo, hi
            end
        end
    end
    best_lo < 0 && return nothing
    table = falses(128)
    wide = false
    for k in best_lo:best_hi
        table .|= tables[k+1]
        wide = wide || wides[k+1]
    end
    return SkipWin(best_hi, best_hi - best_lo + 1, table, wide)
end

"The anchored automaton of a tree (after simplify), or `nothing` when the pattern has none."
build_adfa(root::Node) = build_adfa_with(root, false)

"""
The forward automaton of a tree: the anchored automaton with a new start joined at every unit, behind every thread
already alive (so last in preference, as the search tries later starts after earlier ones). Read over the text from a
start, it says where the first match ends, and its start states say where no thread of an earlier start is alive: the
leftmost match starts at or after the last of them, the forward search of the regex crate.
"""
build_forward_dfa(root::Node) = build_adfa_with(root, true)

"""
Fills `class_of` with the classes of units, those every set has both or neither of, and returns the number of classes.
"""
function unit_classes!(class_of::Vector{UInt8}, nfa::AdfaNfa, words::Bool)
    signatures = Dict{Vector{Bool},Int}()
    for c in 0:127
        sig = Bool[]
        words && push!(sig, is_word_byte(c))
        for s in 0:length(nfa.kind)-1
            nfa.kind[s+1] == A_SET && push!(sig, has(nfa, s, c))
        end
        cls = get!(signatures, sig, length(signatures))
        class_of[c+1] = cls
    end
    return length(signatures)
end

"The states of an automaton being built, by their key."
mutable struct AdfaTable
    ids::Dict{Vector{Int},Int}
    sets::Vector{Vector{Int}}
    bits::Vector{NTuple{2,Bool}}
    trans::Vector{Int}
    at_end::Vector{Bool}
    stride::Int
end

adfa_key(set::Vector{Int}, word::Bool, at_start::Bool) = vcat(set, [-1 - word, -3 - at_start])

"The threads of a forward state with those of the current start numbered as the pattern numbers them."
decode_threads(set::Vector{Int}, n::Int) = [i >= n ? i - n : i for i in set]

function build_adfa_with(root::Node, forward::Bool)
    nfa = AdfaNfa()
    match = add_to!(nfa, A_MATCH, 0)
    start = compile!(nfa, root, match)
    nfa.failed && return nothing
    d = AdfaDet(nfa)
    # In the forward automaton a thread of the start joined at the current unit is kept apart from the threads of
    # earlier starts, as its state's number plus the number of states, so that a state whose threads are all of the
    # current start (a start state) is known: no earlier start can still match.
    n = length(nfa.kind)
    class_of = zeros(UInt8, 128)
    classes = unit_classes!(class_of, nfa, true)
    shift = 0
    while 1 << shift < classes
        shift += 1
    end
    stride = 1 << shift
    sample = zeros(Int, classes)
    for c in 127:-1:0
        sample[class_of[c+1]+1] = c
    end
    # The word bit matters only to a pattern with a boundary and the start bit only to one with a start anchor (each
    # may be reached later, behind an end anchor or a boundary still to pass, so the whole pattern is asked).
    boundaries = any(k -> k == A_WORD || k == A_NOT_WORD, nfa.kind)
    anchors = any(==(A_BOL), nfa.kind)
    t = AdfaTable(Dict{Vector{Int},Int}(), [Int[]], [(false, false)], zeros(Int, stride), [false], stride)
    start_list = [start]
    starts = zeros(Int, 4)
    for k in 0:3
        word, at_start = k & 2 != 0, k & 1 != 0
        first = closure!(d, Int[], start_list, at_start, false, false, false, false)
        forward && (first .+= n)
        s = intern!(t, d, first, word && boundaries, at_start && anchors, n)
        s < 0 && return nothing
        starts[k+1] = s
    end
    resolved, moved = Int[], Int[]
    id = 1
    while id < length(t.sets)
        set = decode_threads(t.sets[id+1], n)
        word, at_start = t.bits[id+1]
        for cl in 0:classes-1
            c = sample[cl+1]
            closure!(d, empty!(resolved), set, at_start, false, true, word, is_word_byte(c))
            flag = 0
            for (j, i) in enumerate(resolved)
                if nfa.kind[i+1] == A_MATCH
                    # A match ends before this unit; only the threads it would have been tried after go on.
                    flag = ADFA_MATCHED
                    resize!(resolved, j - 1)
                    break
                end
            end
            empty!(moved)
            for i in resolved
                nfa.kind[i+1] == A_SET && has(nfa, i, c) && push!(moved, nfa.out[i+1])
            end
            next = closure!(d, Int[], moved, false, false, false, false, false)
            if forward && flag == 0
                for i in closure_on!(d, Int[], start_list, false, false, false, false, false)
                    push!(next, i + n)
                end
            end
            to = intern!(t, d, next, is_word_byte(c) && boundaries, false, n)
            (to < 0 || d.steps < 0) && return nothing
            t.trans[id*stride+cl+1] = to | flag
        end
        id += 1
    end
    fast = UInt32[UInt32(v & ~ADFA_MATCHED) << shift | (v & ADFA_MATCHED != 0 ? FAST_MATCHED : 0x0) for v in t.trans]
    at_end = t.at_end[1:length(t.sets)]
    s4 = (starts[1], starts[2], starts[3], starts[4])
    context = s4[2] != s4[1] || s4[3] != s4[1] || s4[4] != s4[1]
    start_like = forward ? [!isempty(set) && all(>=(n), set) for set in t.sets] : Bool[]
    return AnchoredDfa(class_of, shift, fast, at_end, s4, context, start_like)
end

"""
Gives a list of threads its state, keyed with the bits that matter, or returns -1 when there are too many.
"""
function intern!(t::AdfaTable, d::AdfaDet, set::Vector{Int}, word::Bool, at_start::Bool, n::Int)
    isempty(set) && return ADFA_DEAD
    key = adfa_key(set, word, at_start)
    known = get(t.ids, key, -1)
    known >= 0 && return known
    length(t.sets) >= ADFA_MAX_STATES && return -1
    id = length(t.sets)
    closed = closure!(d, Int[], decode_threads(set, n), at_start, true, true, word, false)
    push!(t.at_end, has_kind(d, closed, A_MATCH))
    append!(t.trans, zeros(Int, t.stride))
    t.ids[key] = id
    push!(t.sets, copy(set))
    push!(t.bits, (word, at_start))
    return id
end

"""
The reverse automaton of the prefixes of a search's anchors, or `nothing` when one holds an assertion or the automaton
is too large.
"""
function build_reverse_dfa(prefixes::Vector{Vector{Node}})
    b = AdfaNfa()
    match = add_to!(b, A_MATCH, 0)
    starts = Int[]
    for prefix in prefixes
        next = match
        for t in prefix
            next = compile_back!(b, t, next)
        end
        push!(starts, next)
    end
    (b.failed || isempty(starts)) && return nothing
    start = starts[end]
    for k in length(starts)-1:-1:1
        start = split!(b, starts[k], start)
    end
    b.failed && return nothing
    d = AdfaDet(b)
    class_of = zeros(UInt8, 128)
    classes = unit_classes!(class_of, b, false)
    shift = 0
    while 1 << shift < classes
        shift += 1
    end
    stride = 1 << shift
    sample = zeros(Int, classes)
    for c in 127:-1:0
        sample[class_of[c+1]+1] = c
    end
    ids = Dict{Vector{Int},Int}()
    sets = [Int[]]
    trans = zeros(Int, 2stride)
    accept = [false, false]
    first = reverse_closure(d, [start])
    ids[first] = 1
    accept[2] = has_kind(d, first, A_MATCH)
    push!(sets, first)
    id = 1
    while id < length(sets)
        for cl in 0:classes-1
            c = sample[cl+1]
            moved = Int[b.out[i+1] for i in sets[id+1] if b.kind[i+1] == A_SET && has(b, i, c)]
            next = reverse_closure(d, moved)
            to = ADFA_DEAD
            if !isempty(next)
                to = get(ids, next, -1)
                if to < 0
                    length(sets) >= ADFA_MAX_STATES && return nothing
                    to = length(sets)
                    push!(accept, has_kind(d, next, A_MATCH))
                    ids[next] = to
                    push!(sets, next)
                    append!(trans, zeros(Int, stride))
                end
            end
            d.steps < 0 && return nothing
            trans[id*stride+cl+1] = to
        end
        id += 1
    end
    fast = UInt32[UInt32(v) << shift | (v != ADFA_DEAD && accept[v+1] ? FAST_MATCHED : 0x0) for v in trans]
    return ReverseDfa(class_of, shift, fast, accept[2])
end

"""
The closure of the reverse automaton, sorted: every thread is kept (any of them reaching the match is a start).
"""
function reverse_closure(d::AdfaDet, from::Vector{Int})
    out = Int[]
    d.generation += 1
    stack = copy(from)
    while !isempty(stack)
        i = pop!(stack)
        d.steps -= 1
        d.mark[i+1] == d.generation && continue
        d.mark[i+1] = d.generation
        if d.nfa.kind[i+1] == A_SPLIT
            push!(stack, d.nfa.alt[i+1], d.nfa.out[i+1])
        else
            push!(out, i)
        end
    end
    return sort!(out)
end
