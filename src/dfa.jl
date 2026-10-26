# A deterministic automaton over ASCII text, for the patterns that need no backtracking (dfa.rs).
#
# The strings a schema tests are short and nearly always ASCII, and most patterns in schemas are small. For such a
# pattern every state set the text can lead to is worked out once, and a match is then one table read per unit.
#
# The automaton reads units below 0x80 only. A text with any other unit is handed back to the backtracking matcher from
# the start, so nothing here needs to know UTF-8 or the Unicode classes: a class is its ASCII members. It takes \b and
# \B (not those of a case-insensitive pattern with the u flag, which fold): a state carries whether the unit before it
# was a word character and whether it is at the start of the text, and a boundary still to pass is passed, or not, when
# the next unit is known (section 4.4 of the design of the .NET reference engine). A pattern whose automaton has more
# states than a byte can number has no automaton. The automaton is built on the first match, not when the pattern is
# compiled, so a program pays nothing for the patterns it never matches.
#
# States of the pattern and of the automaton are numbered from 0, as in the crate.

# The largest program a linear matcher is asked to compile, in the instructions estimated for it before it is written
# (see re2_cost). A counted repetition is written out, so a{1000} is a thousand instructions.
const MAX_RE2_COST = 10_000

"""
An estimate of the number of instructions of the program a linear matcher compiles for a tree (re2.rs). A counted
repetition is written out: x{n,m} is m copies of x, and x{n,} is n copies and a loop. The estimate stops counting above
MAX_RE2_COST.
"""
function re2_cost(n::Node)
    k = n.kind
    k == N_EMPTY && return 0
    if k == N_CAT || k == N_ALT || k == N_GROUP
        cost = length(n.subs) - 1
        for sub in n.subs
            cost += re2_cost(sub)
            cost > MAX_RE2_COST && return MAX_RE2_COST + 1
        end
        return cost
    elseif k == N_REPEAT
        copies = max(n.max == UNBOUNDED ? n.min : n.max, 1)
        # Each copy has the body and one instruction for the choice to enter it.
        body = re2_cost(n.subs[1]) + 1
        (copies > MAX_RE2_COST || body * copies > MAX_RE2_COST) && return MAX_RE2_COST + 1
        return body * copies
    end
    return 1
end

# The states every automaton has. DFA_DEAD: no match can follow. DFA_ACCEPT: a match was found. DFA_BAIL: the text is
# not ASCII.
const DFA_DEAD = 0
const DFA_ACCEPT = 1
const DFA_BAIL = 2
const DFA_FIRST = 3

# An automaton has at most this many states (they are numbered in a byte), built from at most this many states of the
# pattern, in at most this many steps (a step is one state of the pattern looked at while a set is made). The steps
# bound what a pattern too large for an automaton costs before that is known, to about a millisecond.
const MAX_DFA_STATES = 256
const MAX_NFA_STATES = 512
const MAX_DFA_STEPS = 400_000

# The kinds of the pattern's states. K_SET reads one byte of its set and goes to out. K_SPLIT goes to out and to alt,
# reading nothing. K_BOL and K_EOL go to out at the start and at the end of the text. K_WORD and K_NOT_WORD go to out
# where a word boundary holds and where it does not.
const K_SET = 0x00
const K_SPLIT = 0x01
const K_BOL = 0x02
const K_EOL = 0x03
const K_WORD = 0x04
const K_NOT_WORD = 0x05
const K_MATCH = 0x06

struct Dfa
    # The class of each unit below 128: units the pattern does not tell apart share one. Class 0 is every unit that is
    # not ASCII.
    class_of::Vector{UInt8}
    # trans[state << shift | class] (from 1) is the state after a unit.
    trans::Vector{UInt8}
    shift::Int
    start::Int
    # For each state, whether the pattern matches if the text ends there.
    at_end::Vector{Bool}
    # The pattern matches the empty text.
    empty::Bool
end

"""
Whether the pattern matches the text, and false for decided when the text is not ASCII.
"""
function is_match(d::Dfa, text::Text16or8)
    isempty(text) && return d.empty, true
    s = d.start
    s == DFA_ACCEPT && return true, true
    trans, shift, class_of = d.trans, d.shift, d.class_of
    @inbounds for u in text
        # A unit beyond ASCII is in class 0.
        cls = u < 0x80 ? class_of[u+1] : 0x00
        s = Int(trans[(s << shift | cls) + 1])
        s < DFA_FIRST && return s == DFA_ACCEPT, s != DFA_BAIL
    end
    return d.at_end[s+1], true
end

"The states of the pattern, as parallel vectors."
mutable struct Nfa
    kind::Vector{UInt8}
    set0::Vector{UInt64}
    set1::Vector{UInt64}
    out::Vector{Int}
    alt::Vector{Int}
    # The pattern has something an automaton over bytes cannot decide, or is too large.
    failed::Bool
end

Nfa() = Nfa(UInt8[], UInt64[], UInt64[], Int[], Int[], false)

function add!(a::Nfa, k::UInt8, s0::UInt64, s1::UInt64, o::Int, alt::Int)
    if length(a.kind) >= MAX_NFA_STATES
        a.failed = true
        return 0
    end
    push!(a.kind, k)
    push!(a.set0, s0)
    push!(a.set1, s1)
    push!(a.out, o)
    push!(a.alt, alt)
    return length(a.kind) - 1
end

has(a::Nfa, i::Int, c::Int) = c < 64 ? (a.set0[i+1] >> c) & 1 != 0 : (a.set1[i+1] >> (c - 64)) & 1 != 0

"Adds the states of a node that go on to `next`, and returns the state they start at."
function compile!(a::Nfa, n::Node, next::Int)
    a.failed && return 0
    k = n.kind
    if k == N_EMPTY
        return next
    elseif k == N_CHAR
        s0 = 0 <= n.r < 64 ? UInt64(1) << n.r : UInt64(0)
        s1 = 64 <= n.r < 128 ? UInt64(1) << (n.r - 64) : UInt64(0)
        return add!(a, K_SET, s0, s1, next, 0)
    elseif k == N_SET
        return add!(a, K_SET, n.set.ascii[1], n.set.ascii[2], next, 0)
    elseif k == N_CAT
        for sub in Iterators.reverse(n.subs)
            next = compile!(a, sub, next)
        end
        return next
    elseif k == N_ALT
        start = compile!(a, n.subs[end], next)
        for j in length(n.subs)-1:-1:1
            out = compile!(a, n.subs[j], next)
            start = add!(a, K_SPLIT, UInt64(0), UInt64(0), out, start)
        end
        return start
    elseif k == N_GROUP
        return compile!(a, n.subs[1], next)
    elseif k == N_REPEAT
        sub = n.subs[1]
        if n.max == UNBOUNDED
            # The loop, then the copies that must match before it.
            loop = add!(a, K_SPLIT, UInt64(0), UInt64(0), 0, next)
            a.failed && return 0
            body = compile!(a, sub, loop)
            a.out[loop+1] = body
            next = loop
        else
            # The copies that may match, innermost last.
            i = n.min
            while i < n.max && !a.failed
                out = compile!(a, sub, next)
                next = add!(a, K_SPLIT, UInt64(0), UInt64(0), out, next)
                i += 1
            end
        end
        i = 0
        while i < n.min && !a.failed
            next = compile!(a, sub, next)
            i += 1
        end
        return next
    elseif k == N_BOL
        return add!(a, K_BOL, UInt64(0), UInt64(0), next, 0)
    elseif k == N_EOL
        return add!(a, K_EOL, UInt64(0), UInt64(0), next, 0)
    elseif k == N_WORD_BOUNDARY && !n.fold
        return add!(a, K_WORD, UInt64(0), UInt64(0), next, 0)
    elseif k == N_NOT_WORD_BOUNDARY && !n.fold
        return add!(a, K_NOT_WORD, UInt64(0), UInt64(0), next, 0)
    end
    # A word boundary that folds, or anything that needs the backtracking matcher.
    a.failed = true
    return 0
end

"Makes the automaton's states from sets of the pattern's states."
mutable struct DfaBuilder
    a::Nfa
    # The states visited by closure, and its stack.
    mark::Vector{Int}
    generation::Int
    stack::Vector{Int}
    # The steps left (see MAX_DFA_STEPS).
    steps::Int
    # The states of the automaton being built.
    ids::Dict{Vector{Int},Int}
    sets::Vector{Vector{Int}}
    bits::Vector{NTuple{2,Bool}}
    trans::Vector{UInt8}
    at_end::Vector{Bool}
end

"""
Adds to `set` every state that reading nothing reaches from the states in `from`, keeping the states that read a unit,
the anchors and boundaries still to pass, and the match. A start anchor is passed only at_start, and an end anchor only
at_end. A word boundary is kept to pass later when `words` is false, and otherwise (whether the units before and after
the position are word characters) is passed or dropped.
"""
function closure!(b::DfaBuilder, set::Vector{Int}, from::Vector{Int}, at_start::Bool, at_end::Bool, words::Bool,
    before::Bool, after::Bool)
    b.generation += 1
    empty!(b.stack)
    append!(b.stack, from)
    a = b.a
    while !isempty(b.stack)
        i = pop!(b.stack)
        b.steps -= 1
        b.mark[i+1] == b.generation && continue
        b.mark[i+1] = b.generation
        k = a.kind[i+1]
        if k == K_SPLIT
            push!(b.stack, a.out[i+1], a.alt[i+1])
        elseif k == K_BOL
            at_start && push!(b.stack, a.out[i+1])
        elseif k == K_EOL
            at_end ? push!(b.stack, a.out[i+1]) : push!(set, i)
        elseif k == K_WORD || k == K_NOT_WORD
            if !words
                push!(set, i)
            elseif (before != after) == (k == K_WORD)
                push!(b.stack, a.out[i+1])
            end
        else
            push!(set, i)
        end
    end
    return set
end

has_match(b::DfaBuilder, set::Vector{Int}) = any(i -> b.a.kind[i+1] == K_MATCH, set)

"""
A state of the automaton as a key: its states in increasing order, then whether the unit before it was a word
character and whether it is at the start of the text.
"""
dfa_key(set::Vector{Int}, word::Bool, at_start::Bool) = push!(sort(set), (word ? 2 : 0) | (at_start ? 1 : 0) - 4)

"The automaton of a pattern for an unanchored search, or `nothing` when it has none."
function build_dfa(root::Node)
    a = Nfa()
    match = add!(a, K_MATCH, UInt64(0), UInt64(0), 0, 0)
    start_state = compile!(a, root, match)
    a.failed && return nothing

    # The classes of units: two units are in one class when every set of the pattern has both or neither, and both or
    # neither is a word character. Class 0 is the units that are not ASCII.
    class_of = zeros(UInt8, 128)
    classes = 1
    signatures = Dict{Vector{Bool},Int}()
    for c in 0:127
        signature = Bool[is_word_byte(c)]
        for s in 0:length(a.kind)-1
            a.kind[s+1] == K_SET && push!(signature, has(a, s, c))
        end
        cls = get(signatures, signature, 0)
        if cls == 0
            cls = classes
            classes += 1
            signatures[signature] = cls
        end
        class_of[c+1] = cls
    end
    shift = 0
    while 1 << shift < classes
        shift += 1
    end
    # One unit of each class, to move a set by.
    sample = zeros(Int, 129)
    for c in 127:-1:0
        sample[class_of[c+1]+1] = c
    end
    stride = 1 << shift
    b = DfaBuilder(a, zeros(Int, length(a.kind)), 0, Int[], MAX_DFA_STEPS, Dict{Vector{Int},Int}(),
        [Int[] for _ in 1:DFA_FIRST], [(false, false) for _ in 1:DFA_FIRST], zeros(UInt8, DFA_FIRST * stride),
        falses(DFA_FIRST))

    # The search is unanchored: a match may start at any position, so after every unit the states the pattern starts in
    # (not at the start of the text) join the set.
    start_list = [start_state]
    restart = closure!(b, Int[], start_list, false, false, false, false, false)
    for cls in 0:stride-1
        b.trans[DFA_ACCEPT*stride+cls+1] = DFA_ACCEPT
        b.trans[DFA_BAIL*stride+cls+1] = DFA_BAIL
    end
    first = closure!(b, Int[], start_list, true, false, false, false, false)
    s0 = intern!(b, stride, first, false, true)
    s0 < 0 && return nothing
    empty = s0 == DFA_ACCEPT || b.at_end[s0+1]
    resolved, moved, next = Int[], Int[], Int[]
    id = DFA_FIRST
    while id < length(b.sets)
        set = b.sets[id+1]
        word, at_start = b.bits[id+1]
        for cls in 0:stride-1
            if cls == 0 || cls >= classes
                # Not ASCII (or no such class).
                b.trans[id*stride+cls+1] = DFA_BAIL
                continue
            end
            c = sample[cls+1]
            # The boundaries at this position are passed now that the unit after it is known.
            closure!(b, empty!(resolved), set, at_start, false, true, word, is_word_byte(c))
            if has_match(b, resolved)
                b.trans[id*stride+cls+1] = DFA_ACCEPT
                continue
            end
            empty!(moved)
            for i in resolved
                a.kind[i+1] == K_SET && has(a, i, c) && push!(moved, a.out[i+1])
            end
            append!(moved, restart)
            closure!(b, empty!(next), moved, false, false, false, false, false)
            to = intern!(b, stride, next, is_word_byte(c), false)
            (to < 0 || b.steps < 0) && return nothing
            b.trans[id*stride+cls+1] = to
        end
        id += 1
    end
    return Dfa(class_of, b.trans, shift, s0, b.at_end, empty)
end

"Gives a set its state, or returns -1 when there are too many."
function intern!(b::DfaBuilder, stride::Int, set::Vector{Int}, word::Bool, at_start::Bool)
    has_match(b, set) && return DFA_ACCEPT
    isempty(set) && return DFA_DEAD
    key = dfa_key(set, word, at_start)
    known = get(b.ids, key, -1)
    known >= 0 && return known
    length(b.sets) >= MAX_DFA_STATES && return -1
    id = length(b.sets)
    b.ids[key] = id
    push!(b.sets, copy(set))
    push!(b.bits, (word, at_start))
    append!(b.trans, zeros(UInt8, stride))
    # At the end of the text the end anchors are passed, and a boundary is between a unit and none.
    closed = closure!(b, Int[], set, at_start, true, true, word, false)
    push!(b.at_end, has_match(b, closed))
    return id
end
