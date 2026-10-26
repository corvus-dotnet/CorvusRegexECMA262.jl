# Vector compares over 32 bytes or 16 UTF-16 units at a time, written in LLVM's own vector types through llvmcall, which
# LLVM compiles to the machine's vector instructions (AVX2 or SSE on x86, NEON on ARM): a compare of each lane and the
# lanes' results as the bits of one integer, the first lane in the lowest bit. The searches of swar.jl and finder.jl
# read a text in memory of its own (Dense8, Dense16) through them; other vectors keep the SWAR words.

const V8x32 = NTuple{32,VecElement{UInt8}}
const V16x16 = NTuple{16,VecElement{UInt16}}

"The 32 bytes at `at` (from 0), which need not be aligned."
@inline load32(h::Dense8, at::Int) = GC.@preserve h unsafe_load(Ptr{V8x32}(pointer(h, at + 1)))
"The 16 units at `at` (from 0)."
@inline load16(u::Dense16, at::Int) = GC.@preserve u unsafe_load(Ptr{V16x16}(pointer(u, at + 1)))

@inline splat32(b::UInt8) = ntuple(_ -> VecElement(b), Val(32))
@inline splat16(u::UInt16) = ntuple(_ -> VecElement(u), Val(16))

"The lanes of x equal to v."
@inline eq_mask(x::V8x32, v::V8x32) = Base.llvmcall("""
    %c = icmp eq <32 x i8> %0, %1
    %m = bitcast <32 x i1> %c to i32
    ret i32 %m""", UInt32, Tuple{V8x32,V8x32}, x, v)

"The lanes of x that pass a test of the pair search: x | m == v."
@inline eq_or_mask(x::V8x32, m::V8x32, v::V8x32) = Base.llvmcall("""
    %o = or <32 x i8> %0, %1
    %c = icmp eq <32 x i8> %o, %2
    %r = bitcast <32 x i1> %c to i32
    ret i32 %r""", UInt32, Tuple{V8x32,V8x32,V8x32}, x, m, v)

"""
The starts that pass both positions' tests of the pair search, x | m == v at each, the two compares joined before the
move to an integer.
"""
@inline pair_mask(xi::V8x32, mi::V8x32, vi::V8x32, xj::V8x32, mj::V8x32, vj::V8x32) = Base.llvmcall("""
    %oi = or <32 x i8> %0, %1
    %ci = icmp eq <32 x i8> %oi, %2
    %oj = or <32 x i8> %3, %4
    %cj = icmp eq <32 x i8> %oj, %5
    %c = and <32 x i1> %ci, %cj
    %r = bitcast <32 x i1> %c to i32
    ret i32 %r""", UInt32, Tuple{V8x32,V8x32,V8x32,V8x32,V8x32,V8x32}, xi, mi, vi, xj, mj, vj)

"The lanes of x from lo to lo + width."
@inline range_mask(x::V8x32, lo::V8x32, width::V8x32) = Base.llvmcall("""
    %d = sub <32 x i8> %0, %1
    %c = icmp ule <32 x i8> %d, %2
    %r = bitcast <32 x i1> %c to i32
    ret i32 %r""", UInt32, Tuple{V8x32,V8x32,V8x32}, x, lo, width)

"The units of x equal to v."
@inline eq_mask16(x::V16x16, v::V16x16) = Base.llvmcall("""
    %c = icmp eq <16 x i16> %0, %1
    %m = bitcast <16 x i1> %c to i16
    ret i16 %m""", UInt16, Tuple{V16x16,V16x16}, x, v)
