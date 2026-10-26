# The readers of the automata of adfa.jl over a text of either encoding.

"The start state at `start`: where the pattern has no boundary or anchor that looks back, the one."
@inline function start_state(a::AnchoredDfa, input::Text16or8, start::Int)
    a.context || return a.starts[1]
    k = 0
    if start > 0
        c = unit(input, start - 1)
        c < 0x80 && is_word_byte(c) && (k = 2)
    else
        k = 1
    end
    return a.starts[k+1]
end

"""
Where the match that starts at `start` ends, or ADFA_NONE where no match starts there, or ADFA_BAIL where a unit beyond
ASCII was reached and the backtracking matcher decides.
"""
function find(a::AnchoredDfa, input::Text16or8, start::Int)
    s = start_state(a, input, start)
    s == ADFA_DEAD && return ADFA_NONE
    # The state is kept premultiplied by the stride, so a step is one load and an add.
    return run_dfa(a, input, start, UInt32(s) << a.shift)
end

"Reads the automaton from the row `at`: the end of the last match found, or ADFA_NONE or ADFA_BAIL."
function run_dfa(a::AnchoredDfa, input::Text16or8, from::Int, at::UInt32)
    last = ADFA_NONE
    trans, class_of = a.fast, a.class_of
    p = from
    n = length(input)
    @inbounds while p < n
        c = unit(input, p)
        c >= 0x80 && return ADFA_BAIL
        t = trans[at+class_of[c+1]+1]
        t & FAST_MATCHED != 0 && (last = p)
        at = t & ~FAST_MATCHED
        at == 0 && return last
        p += 1
    end
    @inbounds a.at_end[(at>>a.shift)+1] && return p
    return last
end

"find from `start` where the units from `start` to `from` are a prefix whose states `after` gave."
function find_after(a::AnchoredDfa, input::Text16or8, start::Int, from::Int, rows::NTuple{4,UInt32})
    k = 0
    if a.context
        if start > 0
            c = unit(input, start - 1)
            c < 0x80 && is_word_byte(c) && (k = 2)
        else
            k = 1
        end
    end
    row = rows[k+1]
    row == 0 && return ADFA_NONE
    return run_dfa(a, input, from, row)
end

"""
Whether any match starts at `start`, found at the first place one ends: 1 or 0, or ADFA_BAIL when a unit beyond ASCII
is reached first.
"""
function matches_at(a::AnchoredDfa, input::Text16or8, start::Int)
    s = start_state(a, input, start)
    s == ADFA_DEAD && return 0
    trans, class_of = a.fast, a.class_of
    at = UInt32(s) << a.shift
    @inbounds for p in start:length(input)-1
        c = unit(input, p)
        c >= 0x80 && return ADFA_BAIL
        t = trans[at+class_of[c+1]+1]
        t & FAST_MATCHED != 0 && return 1
        at = t
        at == 0 && return 0
    end
    @inbounds return a.at_end[(at>>a.shift)+1] ? 1 : 0
end

"""
Reads the forward automaton from a start state at `from`, and returns the first place at or after `from` where a match
ends (SCAN_MATCH), or where a start state is reached again first, so that no match starts before it (SCAN_IDLE), or the
unit beyond ASCII reached first (SCAN_BAIL); SCAN_NONE at the end of the text with no match.
"""
function scan_dfa(a::AnchoredDfa, input::Text16or8, from::Int)
    shift = a.shift
    row = UInt32(start_state(a, input, from)) << shift
    trans, class_of, start_like = a.fast, a.class_of, a.start_like
    p = from
    n = length(input)
    @inbounds while p < n
        c = unit(input, p)
        c >= 0x80 && return SCAN_BAIL, p
        t = trans[row+class_of[c+1]+1]
        t & FAST_MATCHED != 0 && return SCAN_MATCH, p
        row = t
        p += 1
        start_like[(row>>shift)+1] && return SCAN_IDLE, p
    end
    @inbounds a.at_end[(row>>shift)+1] && return SCAN_MATCH, p
    return SCAN_NONE, p
end

"""
The starts before q, as a mask of their distances (bit d of lo, hi is the start q - d), that the terms allow, looking
no further back than `most` units nor before `floor`; ok false when a unit beyond ASCII is reached.
"""
function starts_before(r::ReverseDfa, input::Text16or8, q::Int, most::Int, floor::Int)
    lo, hi = r.accept_first ? UInt64(1) : UInt64(0), UInt64(0)
    at = UInt32(1) << r.shift
    fast, class_of = r.fast, r.class_of
    reach = min(most, max(q - floor, 0))
    @inbounds for d in 1:reach
        c = unit(input, q - d)
        c >= 0x80 && return UInt64(0), UInt64(0), false
        t = fast[at+class_of[c+1]+1]
        t == 0 && break
        if t & FAST_MATCHED != 0
            if d < 64
                lo |= UInt64(1) << d
            else
                hi |= UInt64(1) << (d - 64)
            end
        end
        at = t & ~FAST_MATCHED
    end
    return lo, hi, true
end

"""
The first place at or after `at` that the window does not rule out: one unit read rules out the starts of a window
none of whose positions it can be.
"""
function skip_ahead(s::SkipWin, input::Text16or8, at::Int)
    n = length(input)
    while at + s.hi < n && !hit(s, unit(input, at + s.hi))
        at += s.len
    end
    return at
end
