# The literals of a search, over UTF-8 and over UTF-16 (Literals of search.rs): a search for the leftmost occurrence of
# any of them, the first in the pattern's order of those that start there. And the sets of UTF-16 code units the
# searches look for (simd16.rs, which the Java engine has as UnitSearch).

# The most units of a literal the packed search takes, so that the chunks' overlap stays short.
const PACKED_LONGEST = 64
# The most share of text (in parts per ten thousand, share16) a unit may have for the UTF-16 search to look for it
# alone.
const INDEX_ALONE = 40
# The most units packed into bytes at a time for the packed search, and the first chunk packed: each chunk after it is
# twice the one before, up to PACK_CHUNK, so that a search whose occurrence is near packs little more than it reads.
const PACK_CHUNK = 4096
const FIRST_PACK = 256

struct Literals
    # The search over UTF-8, and the one literal over UTF-8 when there is one.
    utf8::ByteFinder
    single8::Union{Nothing,Vector{UInt8}}
    # The bytes the UTF-8 literals start with, at index byte + 1.
    firsts::BitVector
    # The most code units of a literal.
    longest::Int
    # Every literal over UTF-16, in the pattern's order.
    all16::Vector{Vector{UInt16}}
    # One literal over UTF-16 with a rare unit, one_unit, at one_at (from 0) in it: the search for that unit, then a
    # compare of the literal. `nothing` otherwise.
    one16::Union{Nothing,Vector{UInt16}}
    one_unit::UInt16
    one_at::Int
    # The rare unit up to four literals over UTF-16 all start with, when has_shared16.
    shared16::UInt16
    has_shared16::Bool
    # The search of the low bytes of several literals over UTF-16 (see find_packed).
    packed16::Union{Nothing,ByteFinder}
end

"""
The search for the literals, each a sequence of code points, with the most bytes of each written out over UTF-8 (see
utf8_cuts).
"""
function Literals(lits::Vector{Vector{Int}}, cuts::Vector{Int})
    # A literal cut to fewer bytes finds the same starts, and one that an earlier literal begins with finds no start the
    # earlier one does not.
    u8 = Vector{UInt8}[]
    all16 = Vector{UInt16}[]
    longest = 0
    for (k, r) in enumerate(lits)
        s = String(Char.(r))
        units = transcode(UInt16, s)
        push!(all16, units)
        longest = max(longest, length(units))
        b = Vector{UInt8}(codeunits(s))
        # A cut inside a character is not made: measured in the Rust crate, the Cyrillic letters with a three-byte form
        # cut so made the search 1.2 times slower.
        cut = cuts[k]
        cut < length(b) && !continuation(b[cut+1]) && (b = b[1:cut])
        covered = any(e -> length(b) >= length(e) && view(b, 1:length(e)) == e, u8)
        covered || push!(u8, b)
    end
    firsts = falses(256)
    for b in u8
        firsts[b[1]+1] = true
    end
    utf8 = byte_finder(u8, BYTE_RANK)
    single8 = length(u8) == 1 ? u8[1] : nothing
    one16, one_unit, one_at = nothing, 0x0000, 0
    if length(all16) == 1
        s, at = all16[1], 0
        for (k, u) in enumerate(s)
            if !is_surrogate(u) && (at == 0 || share16(u) < share16(s[at]))
                at = k
            end
        end
        if at > 0 && share16(s[at]) <= INDEX_ALONE
            one16, one_at, one_unit = s, at - 1, s[at]
        end
    end
    first = all16[1][1]
    shared = 1 < length(all16) <= 4 && !is_surrogate(first) && share16(first) <= INDEX_ALONE &&
             all(s -> s[1] == first, all16)
    packed16 = nothing
    if longest < PACKED_LONGEST
        # The low byte of each unit, as the packed text holds it.
        low = Vector{UInt8}[]
        for s in all16
            b = UInt8[u % UInt8 for u in s]
            b in low || push!(low, b)
        end
        packed16 = byte_finder(low, packed_ranks(all16))
    end
    return Literals(utf8, single8, firsts, longest, all16, one16, one_unit, one_at, first, shared, packed16)
end

# The buffers of the packed search, kept from one search to the next.
const PACKS = Vector{UInt8}[]
const PACKS_LOCK = Threads.SpinLock()

function take_pack()
    lock(PACKS_LOCK)
    b = isempty(PACKS) ? nothing : pop!(PACKS)
    unlock(PACKS_LOCK)
    return b === nothing ? Vector{UInt8}(undef, PACK_CHUNK) : b
end

function give_pack(b::Vector{UInt8})
    lock(PACKS_LOCK)
    push!(PACKS, b)
    unlock(PACKS_LOCK)
end

@inline is_surrogate(u::Integer) = 0xD800 <= u <= 0xDFFF

"The leftmost occurrence at or after `from` in UTF-8 text, as its start and end, or -1."
function find8(l::Literals, h::Bytes, from::Int)
    from > length(h) && return -1, -1
    return find_any(l.utf8, h, from, length(h))
end

"The leftmost occurrence at or after `from` in UTF-16 text, as its start and end, or -1."
function find16(l::Literals, s::Units, from::Int)
    from = max(from, 0)
    one16 = l.one16
    if one16 !== nothing
        at = from + l.one_at
        while true
            p = index_unit(s, at, length(s), l.one_unit)
            p < 0 && return -1, -1
            start = p - l.one_at
            has_units16(s, start, one16) && return start, start + length(one16)
            at = p + 1
        end
    end
    if l.has_shared16
        at = from
        while true
            p = index_unit(s, at, length(s), l.shared16)
            p < 0 && return -1, -1
            for lit in l.all16
                has_units16(s, p, lit) && return p, p + length(lit)
            end
            at = p + 1
        end
    end
    l.packed16 === nothing || return find_packed(l, s, from)
    for p in from:length(s)-1
        e = literal_at16(l, s, p)
        e >= 0 && return p, e
    end
    return -1, -1
end

"Where the first literal in order that starts at p of UTF-16 text ends, or -1."
function literal_at16(l::Literals, s::Units, p::Int)
    c = unit(s, p)
    for lit in l.all16
        lit[1] == c && has_units16(s, p, lit) && return p + length(lit)
    end
    return -1
end

"""
The leftmost occurrence at or after `from` of one of the literals (in the pattern's order, the first of those that
start there): the low bytes of a chunk of units packed into bytes and searched for the low bytes of the literals, each
candidate then compared with the literals themselves (a unit beyond ASCII packs to a byte an ASCII unit has too). The
.NET reference engine's packed search, which the crate makes with the ASCII units alone; the low byte keeps the search
one for every literal. An occurrence that starts so near the end of a chunk that a literal could start before it and
end beyond the chunk is looked for again in the next chunk, which starts that far back. The first chunk is small, and
each after it twice the one before up to the most, so that a search packs at most about twice what it reads: a global
search starts a search after each match, and with a chunk of the most after the first one, a search whose occurrence
was 1,300 units on packed 4,352.
"""
function find_packed(l::Literals, s::Units, from::Int)
    units = length(s)
    from > units && return -1, -1
    overlap = max(l.longest - 1, 0)
    buf = take_pack()
    result = packed_search(l, buf, s, from, units, overlap)
    give_pack(buf)
    return result
end

function packed_search(l::Literals, buf::Vector{UInt8}, s::Units, from::Int, units::Int, overlap::Int)
    # The finder is read here and searched through find_any, so that no call is chosen as the program runs.
    packed = l.packed16::ByteFinder
    size = FIRST_PACK
    at, end_ = from, min(from + size, units)
    while true
        n = end_ - at
        @inbounds for i in 1:n
            buf[i] = s[at+i] % UInt8
        end
        last = end_ == units
        limit = last ? n : n - overlap
        k = 0
        while true
            c, _ = find_any(packed, view(buf, 1:n), k, n)
            (c < 0 || c >= limit) && break
            start = at + c
            for lit in l.all16
                has_units16(s, start, lit) && return start, start + length(lit)
            end
            k = c + 1
        end
        last && return -1, -1
        at, size = end_ - overlap, min(2size, PACK_CHUNK)
        end_ = min(at + size, units)
    end
end

"""
The leftmost occurrence that starts at or after `from` and at or before `last`, in UTF-8 text, or -1. The few bytes
between are looked at one at a time for a literal's first byte before a search is called, since a call on so short a
text costs more than reading it.
"""
function find_within8(l::Literals, h::Bytes, from::Int, last::Int)
    last = min(last, length(h) - 1)
    from > last && return -1
    single8 = l.single8
    if single8 !== nothing
        b = single8[1]
        for p in from:last
            unit(h, p) == b && starts_with(h, p, length(h), single8) && return p
        end
        return -1
    end
    p = from
    while p <= last && !l.firsts[unit(h, p)+1]
        p += 1
    end
    p > last && return -1
    reach = min(last + 3 * l.longest, length(h))
    q, _ = find_any(l.utf8, h, p, reach)
    return q >= 0 && q <= last ? q : -1
end

"find_within8 in UTF-16 text: each start between is looked at, as they are few."
function find_within16(l::Literals, s::Units, from::Int, last::Int)
    last = min(last, length(s) - 1)
    for p in from:last
        literal_at16(l, s, p) >= 0 && return p
    end
    return -1
end

"""
A set of code units as ranges (inclusive pairs), for the units a match can start with and for the units that end a run
of a loop: one unit by the search for it, one range by a compare, and any other set by a table of bits a unit at a
time: a block of 256 bits for each high byte of a unit, the blocks the set has nothing in shared, so that a test is two
loads and a shift.
"""
struct UnitSet
    ranges::Vector{Int}
    # The one unit of a set of one, or -1.
    one::Int
    # The blocks of bits by high byte, for a set of more than one range; nothing otherwise.
    blocks::Union{Nothing,Vector{NTuple{4,UInt64}}}
end

function UnitSet(ranges::Vector{Int})
    one = length(ranges) == 2 && ranges[1] == ranges[2] ? ranges[1] : -1
    blocks = nothing
    if length(ranges) > 2
        b = [ntuple(_ -> UInt64(0), 4) for _ in 1:256]
        for k in 1:2:length(ranges)
            for u in ranges[k]:min(ranges[k+1], 0xFFFF)
                blk = b[(u>>8)+1]
                w = (u >> 6) & 3
                b[(u>>8)+1] = ntuple(i -> i == w + 1 ? blk[i] | UInt64(1) << (u & 63) : blk[i], 4)
            end
        end
        blocks = b
    end
    return UnitSet(ranges, one, blocks)
end

@inline function Base.in(u::UInt16, s::UnitSet)
    blocks = s.blocks
    if blocks !== nothing
        @inbounds return (blocks[(u>>8)+1][((u>>6)&3)+1] >> (u & 63)) & 1 != 0
    end
    return s.ranges[1] <= u <= s.ranges[2]
end

"The first unit at or after `from` in the set, or -1."
function find(s::UnitSet, u::Units, from::Int)
    s.one >= 0 && return index_unit(u, from, length(u), UInt16(s.one))
    blocks = s.blocks
    if blocks !== nothing
        @inbounds for at in from:length(u)-1
            c = u[at+1]
            (blocks[(c>>8)+1][((c>>6)&3)+1] >> (c & 63)) & 1 != 0 && return at
        end
        return -1
    end
    lo, width = s.ranges[1], s.ranges[2] - s.ranges[1]
    @inbounds for at in from:length(u)-1
        0 <= Int(u[at+1]) - lo <= width && return at
    end
    return -1
end
