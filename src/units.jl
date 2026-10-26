# Reading UTF-8 and UTF-16, and matching by UTF-16 code unit over UTF-8 text (units.rs).
#
# ECMA-262 matches a pattern that has no u flag a code unit at a time. A character of one, two or three bytes of UTF-8
# is one code unit. A character of four bytes is two, a high surrogate and a low one, so the matcher has to be able to
# stand between them. That position is written as the offset of the character's third byte. Each half then spans two
# bytes, every position is still an offset into the text, a group is still a pair of offsets, and no UTF-16 copy of
# the text is made.
#
# The third byte of a character is a continuation byte, which is no position at all when matching by code point, so
# the two readings cannot be confused. Only a text with a character of four bytes differs between the two, and the
# instructions that compare bytes (a literal run, a word boundary, a line terminator) need no change: none of them can
# hold at the position between the halves, and all of them are right at every other.
#
# The matcher is written once over a vector of code units and compiled for each encoding, so each operation the Rust
# crate's Text trait has is a function with a method for each: one over UTF-8 bytes (`Bytes`), one over UTF-16 code
# units (`Units`), which may hold lone surrogates. A position is a 0-based offset in the units of the text, as in the
# crate, and `unit(input, p)` reads the unit at it.

const Bytes = AbstractVector{UInt8}
const Units = AbstractVector{UInt16}
const Text16or8 = Union{Bytes,Units}

"The code unit at the 0-based position."
@inline unit(input::AbstractVector, p::Int) = @inbounds input[p+1]

# What a byte that is not UTF-8 decodes to, one byte at a time. The public API refuses text that is not UTF-8, so the
# matcher only meets it in a text the caller vouched for.
const RUNE_ERROR = 0xFFFD % Int
# The first byte value that is not a character by itself.
const RUNE_SELF = 0x80

@inline continuation(b::UInt8) = b & 0xC0 == 0x80

"""
The code point at `pos` of the bytes before `stop` and its width in bytes: (RUNE_ERROR, 1) for bytes that are not
UTF-8, and (RUNE_ERROR, 0) for no bytes.
"""
@inline function decode_rune(p::Bytes, pos::Int, stop::Int=length(p))
    pos >= stop && return RUNE_ERROR, 0
    p0 = unit(p, pos)
    p0 < RUNE_SELF && return Int(p0), 1
    n = stop - pos
    if 0xC2 <= p0 <= 0xDF
        if n >= 2 && continuation(unit(p, pos + 1))
            return Int(p0 & 0x1F) << 6 | Int(unit(p, pos + 1) & 0x3F), 2
        end
    elseif 0xE0 <= p0 <= 0xEF
        if n >= 3 && continuation(unit(p, pos + 2))
            lo, hi = p0 == 0xE0 ? 0xA0 : 0x80, p0 == 0xED ? 0x9F : 0xBF
            p1 = unit(p, pos + 1)
            if lo <= p1 <= hi
                return Int(p0 & 0x0F) << 12 | Int(p1 & 0x3F) << 6 | Int(unit(p, pos + 2) & 0x3F), 3
            end
        end
    elseif 0xF0 <= p0 <= 0xF4
        if n >= 4 && continuation(unit(p, pos + 2)) && continuation(unit(p, pos + 3))
            lo, hi = p0 == 0xF0 ? 0x90 : 0x80, p0 == 0xF4 ? 0x8F : 0xBF
            p1 = unit(p, pos + 1)
            if lo <= p1 <= hi
                return Int(p0 & 0x07) << 18 | Int(p1 & 0x3F) << 12 | Int(unit(p, pos + 2) & 0x3F) << 6 |
                       Int(unit(p, pos + 3) & 0x3F), 4
            end
        end
    end
    return RUNE_ERROR, 1
end

"The code point that ends at `stop` of the bytes from `from` and its width in bytes."
@inline function decode_last_rune(p::Bytes, from::Int, stop::Int)
    stop <= from && return RUNE_ERROR, 0
    last = unit(p, stop - 1)
    last < RUNE_SELF && return Int(last), 1
    # A character is four bytes at most, so its first byte is one of the last four.
    lim = max(stop - 4, from)
    start = stop - 1
    while start > lim
        start -= 1
        continuation(unit(p, start)) || break
    end
    r, size = decode_rune(p, start, stop)
    start + size != stop && return RUNE_ERROR, 1
    return r, size
end

# The two UTF-16 code units of a code point beyond the Basic Multilingual Plane.
@inline high_surrogate(c::Int) = 0xD800 + ((c - 0x10000) >> 10)
@inline low_surrogate(c::Int) = 0xDC00 + ((c - 0x10000) & 0x3FF)

"The UTF-16 code unit at the position of UTF-8 text and the number of bytes it spans."
function unit_at(input::Bytes, pos::Int)
    c = unit(input, pos)
    if c >= 0xF0
        r, w = decode_rune(input, pos)
        w == 4 && return high_surrogate(r), 2
        return RUNE_ERROR, 1
    end
    if 0x80 <= c < 0xC0 && pos >= 2 && unit(input, pos - 2) >= 0xF0
        # Between the halves of the character that starts two bytes back.
        r, w = decode_rune(input, pos - 2)
        w == 4 && return low_surrogate(r), 2
    end
    return decode_rune(input, pos)
end

"The UTF-16 code unit that ends at the position of UTF-8 text and the number of bytes it spans."
function unit_before(input::Bytes, pos::Int)
    r, w = decode_last_rune(input, 0, pos)
    w == 4 && return low_surrogate(r), 2
    if w == 1 && r == RUNE_ERROR && pos >= 2 && length(input) - pos >= 2 && unit(input, pos - 2) >= 0xF0
        # Between the halves of the character that starts two bytes back.
        r2, w2 = decode_rune(input, pos - 2)
        w2 == 4 && return high_surrogate(r2), 2
    end
    return r, w
end

"The code point at the position and its width in units."
@inline decode(input::Bytes, pos::Int) = decode_rune(input, pos)

"The code point that ends at the position and its width."
@inline decode_last(input::Bytes, pos::Int) = decode_last_rune(input, 0, pos)

"The character at the position: a code unit with `units` set, and a code point otherwise."
@inline read_at(input::Bytes, pos::Int, units::Bool) = units ? unit_at(input, pos) : decode_rune(input, pos)

"`read_at` for the character that ends at the position."
@inline read_last(input::Bytes, pos::Int, units::Bool) = units ? unit_before(input, pos) : decode_last_rune(input, 0, pos)

"The width of the last character of input[from:pos), read as it was read going forward from `from`."
function give_back(input::Bytes, from::Int, pos::Int, units::Bool)
    unit(input, pos - 1) < RUNE_SELF && return 1
    units && return unit_before(input, pos)[2]
    return decode_last_rune(input, from, pos)[2]
end

function line_terminator_at(input::Bytes, pos::Int)
    c = unit(input, pos)
    (c == UInt8('\n') || c == UInt8('\r')) && return true
    c == 0xE2 && return pos + 2 < length(input) && unit(input, pos + 1) == 0x80 &&
                        (unit(input, pos + 2) == 0xA8 || unit(input, pos + 2) == 0xA9)
    return false
end

"Whether a line terminator ends at the position. U+2028 and U+2029 are E2 80 A8 and E2 80 A9."
function line_terminator_before(input::Bytes, pos::Int)
    c = unit(input, pos - 1)
    (c == UInt8('\n') || c == UInt8('\r')) && return true
    (c == 0xA8 || c == 0xA9) && return pos >= 3 && unit(input, pos - 3) == 0xE2 && unit(input, pos - 2) == 0x80
    return false
end

"""
Whether the units input[from:to), compared equal to a group's, are the same code points. Over UTF-8 they always are.
"""
whole(input::Bytes, from::Int, to::Int) = true

"""
Appends input[from:to) to `out`. A bound between the halves of a character (which only a pattern without the u flag
can make) cannot be written as UTF-8, and the half character is written as U+FFFD, as a lossy conversion of the UTF-16
text would write it; so the result is UTF-8 when the input is.
"""
function push_lossy!(out::Vector{UInt8}, input::Bytes, from::Int, to::Int)
    from >= to && return out
    if inside_four(input, from)
        append!(out, codeunits("�"))
        from += 2
    end
    tail = to < length(input) && inside_four(input, to)
    tail && (to -= 2)
    from < to && append!(out, view(input, from+1:to))
    tail && append!(out, codeunits("�"))
    return out
end

"""
The position a search from `start` begins at. With the u flag a position inside a character means the character
(RegExpBuiltinExec reads the text as code points); without it every code unit is a position, which over UTF-8 is a
character's first byte or the third byte of a character of four.
"""
function normalize(input::Bytes, start::Int, unicode::Bool)
    (start == 0 || start >= length(input) || !continuation(unit(input, start))) && return start
    lead = start
    while lead > 0 && continuation(unit(input, lead))
        lead -= 1
    end
    !unicode && unit(input, lead) >= 0xF0 && start == lead + 2 && return start
    return lead
end

"""
The position after the character at `pos` (AdvanceStringIndex): a code point with the u flag and a code unit without
it.
"""
function advance(input::Bytes, pos::Int, unicode::Bool)
    pos >= length(input) && return pos + 1
    unicode && return pos + decode_rune(input, pos)[2]
    return pos + unit_at(input, pos)[2]
end

"Whether the position is the one between the halves of a character of four bytes: its third byte."
function inside_four(input::Bytes, pos::Int)
    (pos < 2 || pos >= length(input) || !continuation(unit(input, pos)) || unit(input, pos - 2) < 0xF0) && return false
    return decode_rune(input, pos - 2)[2] == 4
end

@inline is_high(u::Integer) = 0xD800 <= u <= 0xDBFF
@inline is_low(u::Integer) = 0xDC00 <= u <= 0xDFFF

"""
The code point at the position and its width in units: with the u flag a surrogate pair is one code point and a lone
surrogate is a code point of its own.
"""
@inline function decode(input::Units, pos::Int)
    u = unit(input, pos)
    if is_high(u) && pos + 1 < length(input) && is_low(unit(input, pos + 1))
        return 0x10000 + (Int(u) - 0xD800) << 10 + (Int(unit(input, pos + 1)) - 0xDC00), 2
    end
    return Int(u), 1
end

"The code point that ends at the position, and its width."
@inline function decode_last(input::Units, pos::Int)
    u = unit(input, pos - 1)
    if is_low(u) && pos >= 2 && is_high(unit(input, pos - 2))
        return 0x10000 + (Int(unit(input, pos - 2)) - 0xD800) << 10 + (Int(u) - 0xDC00), 2
    end
    return Int(u), 1
end

@inline unit_at(input::Units, pos::Int) = (Int(unit(input, pos)), 1)
@inline unit_before(input::Units, pos::Int) = (Int(unit(input, pos - 1)), 1)

@inline read_at(input::Units, pos::Int, units::Bool) = units ? (Int(unit(input, pos)), 1) : decode(input, pos)
@inline read_last(input::Units, pos::Int, units::Bool) = units ? (Int(unit(input, pos - 1)), 1) : decode_last(input, pos)

function give_back(input::Units, from::Int, pos::Int, units::Bool)
    !units && is_low(unit(input, pos - 1)) && pos >= from + 2 && is_high(unit(input, pos - 2)) && return 2
    return 1
end

@inline is_line_terminator_unit(c::Integer) = c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029

line_terminator_at(input::Units, pos::Int) = is_line_terminator_unit(unit(input, pos))
line_terminator_before(input::Units, pos::Int) = is_line_terminator_unit(unit(input, pos - 1))

"""
Whether the units input[from:to), compared equal to a group's, are the same code points: false only when the
comparison ends inside a surrogate pair of the text, which the u flag reads as one code point.
"""
function whole(input::Units, from::Int, to::Int)
    starts_inside = from > 0 && from < length(input) && is_low(unit(input, from)) && is_high(unit(input, from - 1))
    ends_inside = to > from && to < length(input) && is_high(unit(input, to - 1)) && is_low(unit(input, to))
    return !(starts_inside || ends_inside)
end

function push_lossy!(out::Vector{UInt16}, input::Units, from::Int, to::Int)
    from < to && append!(out, view(input, from+1:to))
    return out
end

function normalize(input::Units, start::Int, unicode::Bool)
    if unicode && start > 0 && start < length(input) && is_low(unit(input, start)) && is_high(unit(input, start - 1))
        return start - 1
    end
    return start
end

function advance(input::Units, pos::Int, unicode::Bool)
    pos >= length(input) && return pos + 1
    unicode && return pos + decode(input, pos)[2]
    return pos + 1
end

"Whether a code unit is one of the 63 ASCII word characters."
@inline is_word_unit(c::Integer) = c < 0x80 && is_word_byte(c)

"""
The position of the last of the ASCII bytes `back` in input[from:to), or `from` when there is none: the give-back of a
greedy single character loop (see set_back), which finds where what follows it can start.
"""
function last_of_back(input::Bytes, from::Int, to::Int, back::Vector{UInt8})
    p = to - 1
    if length(back) == 1
        b = back[1]
        while p >= from
            unit(input, p) == b && return p
            p -= 1
        end
    else
        while p >= from
            unit(input, p) in back && return p
            p -= 1
        end
    end
    return from
end

"Never taken: the give-back search is over UTF-8 alone."
last_of_back(input::Units, from::Int, to::Int, back::Vector{UInt8}) = to
