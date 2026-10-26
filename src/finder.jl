# A search for one of a set of literals in a text's bytes (Finder of search.rs). Its answer is the leftmost occurrence
# at or after a position, the first literal in their order of those that start there, or -1 for none.
#
# The Rust crate takes memchr::memmem, aho-corasick and its packed searcher Teddy; Julia has none of them, so the
# searches here are written on the searches of swar.jl, as the Java and Go engines write them: a byte rare in text by
# memchr, a few literals by two of their byte positions (PairFinder, PCRE2's search, which the crate has as pair8.rs and
# which here takes one literal too, in place of memmem's search for its two rarest bytes), and any other set by a table
# of the bytes at its rarest position (TableFinder).

abstract type ByteFinder end

# find(f, h, from, end_) returns the leftmost occurrence that starts at or after `from` and ends at or before `end_`, as
# its start and end, or (-1, -1) for none.

"""
How common each byte is in text, from 0 (rare) to 255, at index byte + 1: the table memchr::memmem ranks a needle's
bytes by (memchr 2.8, arch/all/packedpair/default_rank.rs; MIT or Unlicense), which pair8.rs takes.
"""
const BYTE_RANK = Int[
    55, 52, 51, 50, 49, 48, 47, 46, 45, 103, 242, 66, 67, 229, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 56, 32,
    31, 30, 29, 28, 255, 148, 164, 149, 136, 160, 155, 173, 221, 222, 134, 122, 232, 202, 215, 224, 208, 220, 204, 187,
    183, 179, 177, 168, 178, 200, 226, 195, 154, 184, 174, 126, 120, 191, 157, 194, 170, 189, 162, 161, 150, 193, 142,
    137, 171, 176, 185, 167, 186, 112, 175, 192, 188, 156, 140, 143, 123, 133, 128, 147, 138, 146, 114, 223, 151, 249,
    216, 238, 236, 253, 227, 218, 230, 247, 135, 180, 241, 233, 246, 244, 231, 139, 245, 243, 251, 235, 201, 196, 240,
    214, 152, 182, 205, 181, 127, 27, 212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80, 98, 96, 97, 81, 207,
    145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82, 108, 118, 141, 113, 129, 119, 125, 165, 117,
    92, 106, 83, 72, 99, 93, 65, 79, 166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
]

"The rank of a byte."
@inline rank_of(rank::Vector{Int}, b::Integer) = @inbounds rank[b+1]

"""
Whether a byte is rare enough in text for a search for it alone to pay: not a lower case letter (but the rarest five),
a space or the commonest punctuation, nor a byte beyond ASCII, where the lead bytes of a script are common.
"""
function rare_byte(b::UInt8)
    (UInt8('A') <= b <= UInt8('Z') || UInt8('0') <= b <= UInt8('9')) && return true
    0x20 < b < 0x7F && !(UInt8('a') <= b <= UInt8('z')) && return !(Char(b) in ",.'\"-")
    return Char(b) in "jqxzk"
end

"""
The rank under which a byte is searched for alone (the capital letters, the digits and the rarest lower case letters):
the search for one byte reads several times as fast as the pair search, so a byte this rare pays for the compares where
it is found.
"""
const ALONE_RANK = 200

"""
The position (from 1) of the byte of a literal with the least share of text (UNIT_SHARE) of those rare enough to be
searched for alone, or 0 for none.
"""
function rarest_alone(l::Vector{UInt8}, rank::Vector{Int})
    best = 0
    for (k, b) in enumerate(l)
        if alone(rank, b) && (best == 0 || unit_share(b) < unit_share(l[best]))
            best = k
        end
    end
    return best
end

"""
Whether a byte is rare enough to be searched for alone: one rare_byte names (the Rust crate's rule), and one the ranks
do not mark common (a byte a UTF-16 literal's unit beyond ASCII packs to, which packed_ranks marks).
"""
alone(rank::Vector{Int}, b::UInt8) = b < 0x80 && rare_byte(b) && rank_of(rank, b) <= ALONE_RANK

"""
Each ASCII unit's share of English text in parts per ten thousand, at index unit + 1: the small letters by their
frequency (the table of the .NET reference engine's needle), the capitals as measured over the Industry texts, the
space and the commonest punctuation, and ten for any other.
"""
const UNIT_SHARE = let r = fill(10, 128)
    per_mille = [102, 73, 66, 60, 56, 54, 50, 49, 48, 34, 32, 22, 22, 19, 19, 18, 16, 16, 15, 12, 8, 6, 2, 2, 1, 1]
    for (k, c) in enumerate("etaoinshrdlcumwfgypbvkjxqz")
        r[Int(c)+1] = per_mille[k] * 10
    end
    per_ten_thousand = [65, 28, 21, 18, 16, 13, 13, 12, 10, 10, 9, 9, 8, 8, 7, 6, 6, 5, 5, 4, 2, 2, 2, 1, 1, 1]
    for (k, c) in enumerate("ITHASWMECBNOYRLDPGFJUVKXQZ")
        r[Int(c)+1] = per_ten_thousand[k]
    end
    for (c, v) in ((' ', 1700), ('\n', 200), ('\r', 200), ('.', 70), (',', 80))
        r[Int(c)+1] = v
    end
    r
end

@inline unit_share(b::Integer) = @inbounds UNIT_SHARE[b+1]

"""
A UTF-16 code unit's share of text in parts per ten thousand, for the choice of the unit a search over UTF-16 looks
for: an ASCII unit as UNIT_SHARE has it; a capital of another alphabet (Latin, Greek, Cyrillic, Armenian) as rare as an
ASCII capital and its small letters as common as the commonest ASCII ones, since a text in that script is mostly them;
anything else rare. The letters are the package's own Unicode tables'.
"""
function share16(u::UInt16)
    u < 0x80 && return unit_share(u)
    if u < 0x250 || 0x370 <= u < 0x590
        UCD.contains(UCD.GC_LU, u) && return 20
        any(t -> UCD.contains(t, u), (UCD.GC_LL, UCD.GC_LT, UCD.GC_LM, UCD.GC_LO)) && return 500
    end
    return 10
end

"""
The search for the literals, in the pattern's order, with how common each byte is (BYTE_RANK over UTF-8, and the ranks
of packed_ranks for the low bytes of UTF-16 units).
"""
function byte_finder(literals::Vector{Vector{UInt8}}, rank::Vector{Int})::ByteFinder
    if length(literals) == 1
        l = literals[1]
        length(l) == 1 && return OneFinder(l[1])
        # The byte with the least share of text of those rare enough to be searched for alone; the pair search where
        # every byte is common. The share, not BYTE_RANK, chooses: BYTE_RANK ranks Sherlock's k rarest, which the
        # Sherlock Holmes text holds 3,595 times to its S's 837. memchr reads a vector at a time and the pair search a
        # word, so any rare byte is searched for alone, as the Java and Go engines do with SWAR.
        best = rarest_alone(l, rank)
        best > 0 && return RareFinder(l, best - 1)
        p = pair_finder(literals, rank)
        p === nothing || return p
        return table_finder(literals, rank)
    end
    f = firsts_finder(literals, rank)
    f === nothing || return f
    p = pair_finder(literals, rank)
    p === nothing || return p
    return table_finder(literals, rank)
end

"""
How common each low byte of the units of UTF-16 literals is in the packed text: an ASCII unit's byte as BYTE_RANK has
it, and a byte any of the literals' units beyond ASCII packs to as common (a Cyrillic letter in Russian text) or nearly
so (a Han character, whose low byte any of thousands share), so that neither is searched for alone or taken for a rare
position.
"""
function packed_ranks(literals::Vector{Vector{UInt16}})
    rank = copy(BYTE_RANK)
    for l in literals, u in l
        if u >= 0x80
            b = u % UInt8
            v = 0x400 <= u <= 0x4FF ? 245 : 230
            rank[b+1] = max(rank[b+1], v)
        end
    end
    return rank
end

"A literal of one byte."
struct OneFinder <: ByteFinder
    b::UInt8
end

function find(f::OneFinder, h::Bytes, from::Int, end_::Int)
    p = index_byte(h, from, end_, f.b)
    return p >= 0 ? (p, p + 1) : (-1, -1)
end

"""
One literal with a byte rare enough in text to be searched for alone: the search for it at its offset k (from 0), then
the literal compared, as V8 searches a literal pattern for its first character.
"""
struct RareFinder <: ByteFinder
    literal::Vector{UInt8}
    k::Int
end

function find(f::RareFinder, h::Bytes, from::Int, end_::Int)
    b = f.literal[f.k+1]
    at = from + f.k
    while at < end_
        p = index_byte(h, at, end_, b)
        p < 0 && return -1, -1
        start = p - f.k
        starts_with(h, start, end_, f.literal) && return start, start + length(f.literal)
        at = p + 1
    end
    return -1, -1
end

"""
Several literals whose bytes at one position are up to four values, or more within a range, each byte rare enough to be
searched for alone: the search for those bytes (or that range) at that position, then the literals with the byte found
there compared in order. Sherlock|Holmes is found by an S or an H, as the regex crate finds Sherlock|Street by its S;
the position is the one whose values are rarest.
"""
struct FirstsFinder <: ByteFinder
    k::Int
    # The number of values a, b, c and d (the last repeated), or -1 for the range lo to hi.
    count::Int
    a::UInt8
    b::UInt8
    c::UInt8
    d::UInt8
    lo::UInt8
    hi::UInt8
    # The literals by their byte at k, in the pattern's order, at index byte + 1.
    by_value::Vector{Vector{Vector{UInt8}}}
end

"The values a position (from 0) of the literals holds, sorted."
position_values(literals::Vector{Vector{UInt8}}, k::Int) = sort!(unique([l[k+1] for l in literals]))

shortest_of(literals) = minimum(length, literals)

function firsts_finder(literals::Vector{Vector{UInt8}}, rank::Vector{Int})
    best_k, best_range, best_cost = -1, false, typemax(Int)
    for k in 0:shortest_of(literals)-1
        v = position_values(literals, k)
        # Up to four values are tested for exactly; more as the range from the least to the greatest, where every byte
        # in it is rare (the capital letters of a list of names), which is one test where the values would be as many.
        is_range = length(v) > 4
        cost, rare = 0, true
        for x in (is_range ? (v[1]:v[end]) : v)
            rare = rare && alone(rank, x)
            cost += 1 << (rank_of(rank, x) ÷ 16)
        end
        # Exact values before a range, then the rarer.
        cost += is_range ? 2 << 20 : 1 << 20
        if rare && cost < best_cost
            best_k, best_range, best_cost = k, is_range, cost
        end
    end
    best_k < 0 && return nothing
    v = position_values(literals, best_k)
    by_value = [Vector{UInt8}[] for _ in 1:256]
    for x in v, l in literals
        l[best_k+1] == x && push!(by_value[x+1], l)
    end
    if best_range
        return FirstsFinder(best_k, -1, 0, 0, 0, 0, v[1], v[end], by_value)
    end
    at(i) = v[min(i, length(v))]
    return FirstsFinder(best_k, length(v), at(1), at(2), at(3), at(4), 0, 0, by_value)
end

function find(f::FirstsFinder, h::Bytes, from::Int, end_::Int)
    at = from + f.k
    while at < end_
        p = if f.count == 1
            index_byte(h, at, end_, f.a)
        elseif f.count == 2
            index_byte2(h, at, end_, f.a, f.b)
        elseif f.count == 3 || f.count == 4
            index_byte4(h, at, end_, f.a, f.b, f.c, f.d)
        else
            index_between(h, at, end_, f.lo, f.hi)
        end
        p < 0 && return -1, -1
        start = p - f.k
        # A byte of the range no literal holds there has no literals.
        @inbounds for l in f.by_value[h[p+1]+1]
            starts_with(h, start, end_, l) && return start, start + length(l)
        end
        at = p + 1
    end
    return -1, -1
end

"""
The tests of a position's values as pairs of a mask and a value, a byte x passing one where x | mask == value: two
values that differ in one bit (the cases of an ASCII letter, the lead bytes of the cases of a Cyrillic letter) make one
test with that bit set, any other value a test of its own. `nothing` where that makes more than `most`.
"""
function position_tests(values::Vector{UInt8}, most::Int)
    used = falses(length(values))
    out = UInt8[]
    for a in eachindex(values)
        used[a] && continue
        used[a] = true
        mask = 0x00
        for b in a+1:length(values)
            bit = values[a] ⊻ values[b]
            if !used[b] && count_ones(bit) == 1
                used[b] = true
                mask = bit
                break
            end
        end
        length(out) == 2most && return nothing
        push!(out, mask, values[a] | mask)
    end
    return out
end

# The most tests of a position of the pair search.
const PAIR_MOST_TESTS = 4
# The most bytes of the literals looked at before they are compared one by one.
const PAIR_CHECKED = 16

"""
The search for a few literals by two of their byte positions, each of whose values are a few tests (position_tests):
PCRE2's search before a match (fast_forward_char_pair_simd in its JIT compiler), which finds Sher[a-z]+|Hol[a-z]+ by an
S or an H with an e or an l two bytes on, and a case-insensitive Holmes by both cases of two of its letters. Eight
starts are tested at a time; each candidate is compared with the literals out of that loop, so that the loop keeps
everything in registers.
"""
struct PairFinder <: ByteFinder
    literals::Vector{Vector{UInt8}}
    # The fewest bytes of a literal.
    shortest::Int
    # The two positions (from 0), and the masks and values of each one's tests, broadcast.
    i::Int
    j::Int
    mi::Vector{UInt64}
    vi::Vector{UInt64}
    mj::Vector{UInt64}
    vj::Vector{UInt64}
    # For each of the first bytes of the literals up to PAIR_CHECKED, the values they hold there (index byte + 1).
    sets::Vector{BitVector}
    # The literals are every sequence of the values sets holds, all of one length (a word's cases written out): a
    # candidate whose bytes pass sets is then a literal, with nothing more to compare.
    every::Bool
end

"""
The search for the literals (of at least two bytes each, in the pattern's order), or `nothing` where no two of their
positions take PAIR_MOST_TESTS tests or fewer each.
"""
function pair_finder(literals::Vector{Vector{UInt8}}, ranks::Vector{Int})
    shortest = shortest_of(literals)
    shortest < 2 && return nothing
    # Each position of few enough tests, with how common its commonest value is.
    values = [position_values(literals, k) for k in 0:shortest-1]
    tests = [position_tests(v, PAIR_MOST_TESTS) for v in values]
    rank = [maximum(v -> rank_of(ranks, v), vs) for vs in values]
    # The pair of the rarest positions, their values apart where any pair has them apart (a run of one byte would pass
    # both otherwise), as PCRE2 chooses; of those as rare, the one of fewer tests.
    bi, bj, best = 0, 0, typemax(Int)
    for apart in (true, false)
        for x in 1:shortest, y in x+1:shortest
            (tests[x] === nothing || tests[y] === nothing || apart && !isdisjoint(values[x], values[y])) && continue
            cost = (rank[x] + rank[y]) << 8 | (length(tests[x]) + length(tests[y]))
            if cost < best
                best, bi, bj = cost, x, y
            end
        end
        bi > 0 && break
    end
    bi == 0 && return nothing
    checked = min(shortest, PAIR_CHECKED)
    sets = [falses(256) for _ in 1:checked]
    for k in 1:checked, l in literals
        sets[k][l[k]+1] = true
    end
    every = shortest <= PAIR_CHECKED && all(l -> length(l) == shortest, literals)
    product = 1
    k = 1
    while k <= shortest && every
        product *= length(values[k])
        every = product <= length(literals)
        k += 1
    end
    every = every && product == length(literals)
    each(t, which) = [broadcast8(t[2k+which]) for k in 0:length(t)÷2-1]
    return PairFinder(literals, shortest, bi - 1, bj - 1, each(tests[bi], 1), each(tests[bi], 2), each(tests[bj], 1),
        each(tests[bj], 2), sets, every)
end

"Where the literal that starts at `at` ends (the first in the pattern's order), or -1."
function literal_at(f::PairFinder, h::Bytes, at::Int, end_::Int)
    n = min(length(f.sets), end_ - at)
    @inbounds for k in 1:n
        f.sets[k][h[at+k]+1] || return -1
    end
    f.every && return at + f.shortest
    for l in f.literals
        starts_with(h, at, end_, l) && return at + length(l)
    end
    return -1
end

"""
The lanes of a word that pass the tests, by the cheap test of has_zero, which may flag a lane that does not pass but
never misses one: every candidate is compared with the literals.
"""
@inline function pass(x::UInt64, m::Vector{UInt64}, v::Vector{UInt64})
    out = has_zero((x | m[1]) ⊻ v[1])
    @inbounds for k in 2:length(m)
        out |= has_zero((x | m[k]) ⊻ v[k])
    end
    return out
end

function find(f::PairFinder, h::Bytes, from::Int, end_::Int)
    last = end_ - f.shortest
    from > last && return -1, -1
    at = from
    # The last start whose two words are within the text.
    blocks = end_ - 8 - max(f.i, f.j)
    if length(f.mi) == 1 && length(f.mj) == 1
        mi, vi, mj, vj = f.mi[1], f.vi[1], f.mj[1], f.vj[1]
        while at <= blocks
            m = has_zero((word(h, at + f.i) | mi) ⊻ vi) & has_zero((word(h, at + f.j) | mj) ⊻ vj)
            while m != 0
                s = at + lane(m)
                if s <= last
                    e = literal_at(f, h, s, end_)
                    e >= 0 && return s, e
                end
                m &= m - 1
            end
            at += 8
        end
    else
        while at <= blocks
            m = pass(word(h, at + f.i), f.mi, f.vi) & pass(word(h, at + f.j), f.mj, f.vj)
            while m != 0
                s = at + lane(m)
                if s <= last
                    e = literal_at(f, h, s, end_)
                    e >= 0 && return s, e
                end
                m &= m - 1
            end
            at += 8
        end
    end
    while at <= last
        e = literal_at(f, h, at, end_)
        e >= 0 && return at, e
        at += 1
    end
    return -1, -1
end

"""
Any set of literals: a table of the bytes the literals hold at their rarest position, read a byte at a time, and the
literals that start with the byte found compared in order. The search the crate makes with Teddy and with
aho-corasick's automaton, where no two positions take few enough tests for PairFinder.
"""
struct TableFinder <: ByteFinder
    k::Int
    at::BitVector
    shortest::Int
    # The literals by their first byte, in the pattern's order, at index byte + 1.
    by_first::Vector{Vector{Vector{UInt8}}}
end

function table_finder(literals::Vector{Vector{UInt8}}, rank::Vector{Int})
    shortest = shortest_of(literals)
    best_k, best_cost = 0, typemax(Int)
    for k in 0:shortest-1
        cost = sum(v -> 1 << (rank_of(rank, v) ÷ 16), position_values(literals, k))
        if cost < best_cost
            best_cost, best_k = cost, k
        end
    end
    at = falses(256)
    by_first = [Vector{UInt8}[] for _ in 1:256]
    for l in literals
        at[l[best_k+1]+1] = true
        push!(by_first[l[1]+1], l)
    end
    return TableFinder(best_k, at, shortest, by_first)
end

function find(f::TableFinder, h::Bytes, from::Int, end_::Int)
    last, k = end_ - f.shortest, f.k
    @inbounds for s in from:last
        if f.at[h[s+k+1]+1]
            for l in f.by_first[h[s+1]+1]
                starts_with(h, s, end_, l) && return s, s + length(l)
            end
        end
    end
    return -1, -1
end

"""
The search of a finder held in a field of the abstract type: a branch for each kind of finder, so that each call is
made to its method directly and its answer is not boxed, as a call chosen when the program runs would be. (A method of
`find` for the abstract type would not do: Julia infers no answer for a call that several methods can take.)
"""
@inline function find_any(f::ByteFinder, h::Bytes, from::Int, end_::Int)
    f isa RareFinder && return find(f, h, from, end_)
    f isa PairFinder && return find(f, h, from, end_)
    f isa FirstsFinder && return find(f, h, from, end_)
    f isa OneFinder && return find(f, h, from, end_)
    return find(f::TableFinder, h, from, end_)
end
