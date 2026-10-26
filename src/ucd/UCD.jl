"""
    UCD

The Unicode Character Database properties the engine reads, for one fixed version of Unicode (ucd.rs of the Rust
crate).

Nothing in the engine takes Unicode properties from Julia's own, because those follow the Julia release. With its own
tables the package gives the same answers whatever Julia runs it, and the answers change only when the tables are
generated again. `VERSION` in tables_gen.jl names the version of Unicode they hold.

The tables are in tables_gen.jl, which tools/unicode/gen_tables.py writes from the Rust crate's tables_gen.rs, so every
engine holds the same data. Each is a sorted list of inclusive ranges, the code points up to U+FFFF as 16-bit bounds
and the rest as 32-bit bounds. A value that follows from other values (a General_Category group such as L, the
Assigned property, the Unknown script) has no table of its own and is built when it is first asked for.

Code points are `Int`s here and in the rest of the engine, and ranges are vectors of inclusive pairs, lo then hi.
"""
module UCD

# The last Unicode code point.
const MAX_RUNE = 0x10FFFF

"""
An immutable set of code points. `r16` holds the ranges that end at or below U+FFFF and `r32` the ranges that start
above it, each as inclusive pairs in ascending order. No two ranges of one list overlap or touch.
"""
struct Table
    r16::Vector{UInt16}
    r32::Vector{UInt32}
end

"""
Maps some of the code points first, first + 1, ... first + length - 1 to themselves plus delta. The ones it maps are
those whose offset from first has none of the bits of mask, so a mask of 1 takes every other code point.
"""
struct CaseRange
    first::Int32
    delta::Int32
    length::UInt16
    mask::UInt16
end

include("tables_gen.jl")

function search(ranges::Vector{T}, c::T) where {T}
    lo, hi = 0, length(ranges) >> 1
    @inbounds while lo < hi
        mid = (lo + hi) >> 1
        if c > ranges[2mid+2]
            lo = mid + 1
        elseif c < ranges[2mid+1]
            hi = mid
        else
            return true
        end
    end
    return false
end

"Whether the table holds the code point."
function contains(t::Table, r::Integer)
    r <= 0xFFFF ? search(t.r16, UInt16(r)) : search(t.r32, UInt32(r))
end

"""
Appends the ranges of the table to `dst` as inclusive pairs in ascending order. The pairs neither overlap nor touch.
"""
function append_ranges!(dst::Vector{Int}, t::Table)
    sizehint!(dst, length(dst) + length(t.r16) + length(t.r32))
    for c in t.r16
        push!(dst, Int(c))
    end
    first = 1
    # A range that crosses U+FFFF is stored in two parts.
    if !isempty(t.r16) && !isempty(t.r32) && t.r16[end] == 0xFFFF && t.r32[1] == 0x10000
        dst[end] = Int(t.r32[2])
        first = 3
    end
    for k in first:length(t.r32)
        push!(dst, Int(t.r32[k]))
    end
    return dst
end

"The ranges of the table as inclusive pairs."
ranges(t::Table) = append_ranges!(Int[], t)

"The ranges of the code points that any of the tables holds."
function union_of(tables::Table...)
    all = Int[]
    for t in tables
        append_ranges!(all, t)
    end
    order = sort!(collect(1:(length(all)>>1)), alg=Base.Sort.DEFAULT_STABLE, by=i -> all[2i-1])
    merged = Int[]
    for i in order
        lo, hi = all[2i-1], all[2i]
        if !isempty(merged) && lo <= merged[end] + 1
            merged[end] = max(merged[end], hi)
            continue
        end
        push!(merged, lo, hi)
    end
    return merged
end

"The ranges of the code points that the table does not hold."
function complement_of(t::Table)
    pairs = ranges(t)
    inverse = Int[]
    next = 0
    for i in 1:2:length(pairs)-1
        lo, hi = pairs[i], pairs[i+1]
        lo > next && push!(inverse, next, lo - 1)
        next = hi + 1
    end
    next <= MAX_RUNE && push!(inverse, next, MAX_RUNE)
    return inverse
end

# Each value built from others, on first use, and kept.
const BUILT = Dict{Symbol,Vector{Int}}()
const BUILT_LOCK = ReentrantLock()

function built(name::Symbol, make)
    lock(BUILT_LOCK) do
        get!(make, BUILT, name)
    end
end

# The Script value Katakana_Or_Hiragana (Hrkt). PropertyValueAliases.txt lists the value, and no code point has it, in
# Script or in Script_Extensions. Scripts.txt has no line for it, so the generated tables do not have it.
const KATAKANA_OR_HIRAGANA = Table(UInt16[], UInt32[])

const GROUPS = Dict{String,Function}(
    "L" => () -> union_of(GC_LU, GC_LL, GC_LT, GC_LM, GC_LO),
    "LC" => () -> union_of(GC_LU, GC_LL, GC_LT),
    "M" => () -> union_of(GC_MN, GC_MC, GC_ME),
    "N" => () -> union_of(GC_ND, GC_NL, GC_NO),
    "P" => () -> union_of(GC_PC, GC_PD, GC_PS, GC_PE, GC_PI, GC_PF, GC_PO),
    "S" => () -> union_of(GC_SM, GC_SC, GC_SK, GC_SO),
    "Z" => () -> union_of(GC_ZS, GC_ZL, GC_ZP),
    "C" => () -> union_of(GC_CC, GC_CF, GC_CS, GC_CO, GC_CN),
)

unknown_script() = built(:unknown, () -> union_of(GC_CN, GC_CO, GC_CS))

"""
The ranges of a General_Category value by its short name, such as "Lu" or "L", as a fresh vector the caller may
change, or `nothing` for any other name.
"""
function category(name::AbstractString)
    make = get(GROUPS, name, nothing)
    make === nothing || return copy(built(Symbol("gc_", name), make))
    t = get(CATEGORY_TABLES, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"""
The ranges of a binary property by its canonical name, such as "Alphabetic" or "White_Space", or `nothing` for any
other name. ASCII and Any, which ECMA-262 adds to the properties of Unicode, are not here.
"""
function binary(name::AbstractString)
    name == "Assigned" && return copy(built(:assigned, () -> complement_of(GC_CN)))
    t = get(BINARY_TABLES, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"The generated table of a binary property, for the callers that test one code point, or `nothing`."
binary_table(name::AbstractString) = get(BINARY_TABLES, name, nothing)

"""
The ranges of a Script value by its long name or an alias, such as "Greek" or "Grek", or `nothing` for any other name.
"""
function script(name::AbstractString)
    name in ("Unknown", "Zzzz") && return copy(unknown_script())
    name in ("Katakana_Or_Hiragana", "Hrkt") && return Int[]
    t = get(SCRIPT_TABLES, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"""
The ranges of a Script_Extensions value by the long name of the script or an alias, or `nothing` for any other name.
"""
function script_extensions(name::AbstractString)
    name in ("Unknown", "Zzzz") && return copy(unknown_script())
    name in ("Katakana_Or_Hiragana", "Hrkt") && return Int[]
    t = get(SCRIPT_EXTENSIONS_TABLES, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"The names of every script: each element is the long name of one script followed by its aliases."
script_names() = SCRIPT_NAMES

"The canonical name of every binary property that has a table, which is every name `binary` knows but Assigned."
binary_names() = BINARY_NAMES

function map_case(table::Vector{CaseRange}, r::Int)
    lo, hi = 0, length(table)
    @inbounds while lo < hi
        mid = (lo + hi) >> 1
        row = table[mid+1]
        if r < row.first
            hi = mid
        else
            offset = r - row.first
            if offset >= row.length
                lo = mid + 1
            elseif offset & row.mask == 0
                return r + Int(row.delta)
            else
                return r
            end
        end
    end
    return r
end

"""
The simple case folding of a code point (the C and S rows of CaseFolding.txt), which is the code point itself when it
has none. Two code points are equal ignoring case when `fold` gives the same result for both.
"""
fold(r::Integer) = fold(Int(r))
function fold(r::Int)
    if r < 0x80
        return 'A' <= Char(r) <= 'Z' ? r + 32 : r
    end
    return map_case(CASE_FOLDS, r)
end

"The simple uppercase mapping of a code point, which is the code point itself when it has none."
to_upper(r::Integer) = to_upper(Int(r))
function to_upper(r::Int)
    if r < 0x80
        return 'a' <= Char(r) <= 'z' ? r - 32 : r
    end
    return map_case(UPPER_CASES, r)
end

"Every code point that `fold` changes, in ascending order."
function folding()
    dst = Int[]
    for row in CASE_FOLDS
        for offset in 0:Int(row.length)-1
            if offset & row.mask == 0 && row.delta != 0
                push!(dst, row.first + offset)
            end
        end
    end
    return dst
end

end
