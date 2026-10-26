# The searches the Rust crate takes from memchr. One byte is libc's memchr, which is vector code; two to four bytes, a
# range of bytes, and units of UTF-16 text are SWAR: eight bytes of a UInt64 read at a time and tested together. A lane
# test is exact (no lane is flagged that does not pass), so the first flagged lane is the first unit that passes.
#
# A text in memory of its own (a Vector, the code units of a String, a contiguous view of either) is read a word at a
# time through its pointer; any other vector a unit at a time, with the same answers.

const ONES = 0x0101010101010101
const LOW7 = 0x7F7F7F7F7F7F7F7F
const HIGHS = 0x8080808080808080

"The byte vectors whose memory is one block, read through a pointer."
const Dense8 = Union{Vector{UInt8},Base.CodeUnits{UInt8,String},Base.FastContiguousSubArray{UInt8,1,Vector{UInt8}},
    Base.FastContiguousSubArray{UInt8,1,Base.CodeUnits{UInt8,String}}}
"The vectors of UTF-16 code units whose memory is one block."
const Dense16 = Union{Vector{UInt16},Base.FastContiguousSubArray{UInt16,1,Vector{UInt16}}}

"The eight bytes at `at` (from 0), the first in the low byte."
@inline word(h::Dense8, at::Int) = GC.@preserve h ltoh(unsafe_load(Ptr{UInt64}(pointer(h, at + 1))))
@inline function word(h::Bytes, at::Int)
    w = UInt64(0)
    @inbounds for k in 7:-1:0
        w = w << 8 | h[at+k+1]
    end
    return w
end

"A byte in every lane."
@inline broadcast8(b::UInt8) = UInt64(b) * ONES

"The high bit of each lane of x that is zero."
@inline zeros8(x::UInt64) = ~(((x & LOW7) + LOW7) | x | LOW7)

"The high bit of each lane of x that equals the broadcast byte v."
@inline eq8(x::UInt64, v::UInt64) = zeros8(x ⊻ v)

"The lane of the lowest flagged high bit."
@inline lane(flags::UInt64) = trailing_zeros(flags) >> 3

"""
The cheap test of whether some lane of x is zero: it flags every zero lane but may also flag a lane of 1 above a zero
lane. The loops use it to know that a block holds a byte they look for, and zeros8 to find which; a finder that tests
candidates can take its flags as they are.
"""
@inline has_zero(x::UInt64) = (x - ONES) & ~x & HIGHS

"The first position at or after `from` and before `n` whose byte is b, or -1."
@inline function index_byte(h::Dense8, from::Int, n::Int, b::UInt8)
    from >= n && return -1
    p = GC.@preserve h ccall(:memchr, Ptr{UInt8}, (Ptr{UInt8}, Cint, Csize_t), pointer(h, from + 1), b, n - from)
    p == C_NULL && return -1
    return from + Int(p - pointer(h, from + 1))
end

@inline function index_byte(h::Bytes, from::Int, n::Int, b::UInt8)
    @inbounds for at in from:n-1
        h[at+1] == b && return at
    end
    return -1
end

"The first position at or after `from` and before `n` whose byte is a or b, or -1."
function index_byte2(h::Bytes, from::Int, n::Int, a::UInt8, b::UInt8)
    va, vb = broadcast8(a), broadcast8(b)
    at = from
    while at <= n - 16
        w0, w1 = word(h, at), word(h, at + 8)
        if has_zero(w0 ⊻ va) | has_zero(w0 ⊻ vb) | has_zero(w1 ⊻ va) | has_zero(w1 ⊻ vb) != 0
            z = eq8(w0, va) | eq8(w0, vb)
            z != 0 && return at + lane(z)
            return at + 8 + lane(eq8(w1, va) | eq8(w1, vb))
        end
        at += 16
    end
    while at <= n - 8
        w = word(h, at)
        x = eq8(w, va) | eq8(w, vb)
        x != 0 && return at + lane(x)
        at += 8
    end
    @inbounds while at < n
        (h[at+1] == a || h[at+1] == b) && return at
        at += 1
    end
    return -1
end

"The first position at or after `from` and before `n` whose byte is one of four (which may repeat), or -1."
function index_byte4(h::Bytes, from::Int, n::Int, a::UInt8, b::UInt8, c::UInt8, d::UInt8)
    va, vb, vc, vd = broadcast8(a), broadcast8(b), broadcast8(c), broadcast8(d)
    at = from
    while at <= n - 8
        w = word(h, at)
        if has_zero(w ⊻ va) | has_zero(w ⊻ vb) | has_zero(w ⊻ vc) | has_zero(w ⊻ vd) != 0
            return at + lane(eq8(w, va) | eq8(w, vb) | eq8(w, vc) | eq8(w, vd))
        end
        at += 8
    end
    @inbounds while at < n
        x = h[at+1]
        (x == a || x == b || x == c || x == d) && return at
        at += 1
    end
    return -1
end

"""
The high bit of each lane of x that is an ASCII byte from lo to hi (both below 0x80), given the constants of
between_lo and between_hi: exact, since the seven low bits of a lane plus a constant below 0x80 cannot carry into the
next lane.
"""
@inline function between(x::UInt64, lo::UInt64, hi::UInt64)
    t = x & LOW7
    return (t + lo) & ~(t + hi) & ~x & HIGHS
end

@inline between_lo(lo::UInt8) = broadcast8(0x80 - lo)
@inline between_hi(hi::UInt8) = broadcast8(0x7F - hi)

"The first position at or after `from` and before `n` whose byte is from lo to hi (both below 0x80), or -1."
function index_between(h::Bytes, from::Int, n::Int, lo::UInt8, hi::UInt8)
    vl, vh = between_lo(lo), between_hi(hi)
    at = from
    while at <= n - 16
        z0, z1 = between(word(h, at), vl, vh), between(word(h, at + 8), vl, vh)
        if z0 | z1 != 0
            z0 != 0 && return at + lane(z0)
            return at + 8 + lane(z1)
        end
        at += 16
    end
    while at <= n - 8
        z = between(word(h, at), vl, vh)
        z != 0 && return at + lane(z)
        at += 8
    end
    @inbounds while at < n
        x = h[at+1]
        lo <= x <= hi && return at
        at += 1
    end
    return -1
end

"Whether the bytes of `literal` are at `at` of h, before `end_`."
@inline function starts_with(h::Bytes, at::Int, end_::Int, literal::AbstractVector{UInt8})
    end_ - at >= length(literal) || return false
    @inbounds for k in 1:length(literal)
        h[at+k] == literal[k] || return false
    end
    return true
end

# The same over UTF-16: four units of a UInt64.

const ONES16 = 0x0001000100010001
const LOW15 = 0x7FFF7FFF7FFF7FFF
const HIGHS16 = 0x8000800080008000

"The four units at `at`, the first in the low unit."
@inline word16(u::Dense16, at::Int) = GC.@preserve u ltoh(unsafe_load(Ptr{UInt64}(pointer(u, at + 1))))
@inline function word16(u::Units, at::Int)
    @inbounds UInt64(u[at+1]) | UInt64(u[at+2]) << 16 | UInt64(u[at+3]) << 32 | UInt64(u[at+4]) << 48
end

@inline zeros16(x::UInt64) = ~(((x & LOW15) + LOW15) | x | LOW15)

@inline has_zero16(x::UInt64) = (x - ONES16) & ~x & HIGHS16

"The first position at or after `from` and before `n` whose unit is v, or -1."
function index_unit(u::Units, from::Int, n::Int, v::UInt16)
    vv = UInt64(v) * ONES16
    at = from
    while at <= n - 16
        w0, w1, w2, w3 = word16(u, at) ⊻ vv, word16(u, at + 4) ⊻ vv, word16(u, at + 8) ⊻ vv, word16(u, at + 12) ⊻ vv
        if has_zero16(w0) | has_zero16(w1) | has_zero16(w2) | has_zero16(w3) != 0
            for (k, w) in enumerate((w0, w1, w2, w3))
                z = zeros16(w)
                z != 0 && return at + 4 * (k - 1) + trailing_zeros(z) >> 4
            end
        end
        at += 16
    end
    while at <= n - 4
        z = zeros16(word16(u, at) ⊻ vv)
        z != 0 && return at + trailing_zeros(z) >> 4
        at += 4
    end
    @inbounds while at < n
        u[at+1] == v && return at
        at += 1
    end
    return -1
end

"Whether the units of `literal` are at `at` of u."
@inline function has_units16(u::Units, at::Int, literal::AbstractVector{UInt16})
    (length(u) - at < length(literal) || at < 0) && return false
    @inbounds for k in 1:length(literal)
        u[at+k] == literal[k] || return false
    end
    return true
end
