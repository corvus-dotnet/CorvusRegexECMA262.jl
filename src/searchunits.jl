# The parts of the searches of the matcher that differ between the encodings beyond the unit, a method for each.

"""
The first position at or after `at` whose unit a member of the first set can start with, or -1; `at` itself where the
search has no first units. Over UTF-16, with the u or v flag the trail half of a pair is not a character a match can
start at.
"""
function first_find(p::Program, input::Bytes, at::Int)
    fb = p.search.first_bytes
    return fb === nothing ? at : find(fb, input, at)
end

function first_find(p::Program, input::Units, at::Int)
    fu = p.search.first_units
    fu === nothing && return at
    while true
        at = find(fu, input, at)
        (at < 0 || p.units || !mid_pair(input, at)) && return at
        at += 1
    end
end

"""
first_find for the scan, which passes over the trail half of a pair itself, so that the skip is run from the place
after it.
"""
first_start(p::Program, input::Bytes, at::Int) = first_find(p, input, at)

function first_start(p::Program, input::Units, at::Int)
    fu = p.search.first_units
    return fu === nothing ? at : find(fu, input, at)
end

"Whether the position is between the halves of a surrogate pair."
mid_pair(input::Bytes, at::Int) = false
mid_pair(input::Units, at::Int) = 0 < at < length(input) && is_low(unit(input, at)) && is_high(unit(input, at - 1))

"The end of the run of the loop's members that starts at `at`, or -1 to find it a member at a time."
function run_end(s::Search, input::Bytes, at::Int)
    n = length(input)
    k = s.run_end
    k == RUN_ALL && return n
    if k == RUN_STOPS
        f = if s.n_stops == 1
            index_byte(input, at, n, s.stops[1])
        elseif s.n_stops == 2
            index_byte2(input, at, n, s.stops[1], s.stops[2])
        else
            index_byte4(input, at, n, s.stops[1], s.stops[2], s.stops[3], s.stops[3])
        end
        return f < 0 ? n : f
    elseif k == RUN_LINE
        j = at
        while true
            j = index_byte4(input, j, n, UInt8('\n'), UInt8('\r'), 0xE2, 0xE2)
            j < 0 && return n
            if unit(input, j) != 0xE2 || j + 2 < n && unit(input, j + 1) == 0x80 && unit(input, j + 2) | 0x01 == 0xA9
                return j
            end
            j += 1
        end
    end
    return -1
end

function run_end(s::Search, input::Units, at::Int)
    k = s.run_end
    k == RUN_ALL && return length(input)
    if k == RUN_STOPS || k == RUN_LINE
        f = find(s.stops16::UnitSet, input, at)
        return f >= 0 ? f : length(input)
    end
    return -1
end

"""
Where the match that starts at q ends, for a pattern every match of which starts with the one literal found at q: the
anchored automaton goes on after it. Or ADFA_NONE, or ADFA_BAIL where the matcher decides. Over UTF-16 the literal's
states are not known: the matcher decides.
"""
function after_find(p::Program, input::Bytes, q::Int)
    rows = p.after_literal
    rows === nothing && return ADFA_BAIL
    return find_after(p.anchored_dfa::AnchoredDfa, input, q, q + p.after_length, rows)
end

after_find(p::Program, input::Units, q::Int) = ADFA_BAIL

"The leftmost occurrence of the search's literals at or after `from`, in either encoding."
find_literals(l::Literals, input::Bytes, from::Int) = find8(l, input, from)
find_literals(l::Literals, input::Units, from::Int) = find16(l, input, from)
find_within(l::Literals, input::Bytes, from::Int, last::Int) = find_within8(l, input, from, last)
find_within(l::Literals, input::Units, from::Int, last::Int) = find_within16(l, input, from, last)
