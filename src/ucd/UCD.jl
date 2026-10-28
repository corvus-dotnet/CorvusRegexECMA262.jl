"""
    UCD

The Unicode Character Database properties the engine reads, for each version of Unicode the package carries (ucd.rs
of the Rust crate): `V13`, `V17` and `V18`, each a `Ucd`.

Nothing in the engine takes Unicode properties from Julia's own, because those follow the Julia release. With its own
tables the package gives the same answers whatever Julia runs it, and the answers change only when the tables are
generated again. A pattern is read with the tables of the version it was compiled for.

The tables of a version are in tables<major>_gen.jl and its properties of strings in strings<major>_gen.jl, which
tools/unicode writes from the Rust crate's tables<major>.rs and strings<major>.rs, so every engine holds the same data;
each pair is the module `Tables<major>` here. Each is a sorted list of inclusive ranges, the code points up to U+FFFF as 16-bit bounds
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

# The generated data of each version, a module each with the same names.
module Tables13
import ..Table, ..CaseRange
include("tables13_gen.jl")
include("strings13_gen.jl")
end

module Tables17
import ..Table, ..CaseRange
include("tables17_gen.jl")
include("strings17_gen.jl")
end

module Tables18
import ..Table, ..CaseRange
include("tables18_gen.jl")
include("strings18_gen.jl")
end

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

"""
The Unicode of one version: its generated data, and what is built from it on first use and then kept (`built`), the
General_Category groups, the case folding classes, the property sets and the properties of strings among them.

It is a mutable struct of constant fields so that the parser, which holds one, holds a reference: an immutable struct
of these fields would be stored inline, and every read of it would copy its fields, and root each, on the stack.
"""
mutable struct Ucd
    const version::String
    const major::Int
    const category_tables::Dict{String,Table}
    const binary_tables::Dict{String,Table}
    const script_tables::Dict{String,Table}
    const script_extensions_tables::Dict{String,Table}
    const script_names::Vector{Vector{String}}
    const binary_names::Vector{String}
    const case_folds::Vector{CaseRange}
    const upper_cases::Vector{CaseRange}
    "The properties of strings of the v flag (strings<major>_gen.jl)."
    const strings::Vector{NTuple{3,String}}
    const built::Dict{Any,Any}
    const lock::ReentrantLock
end

function Ucd(m::Module)
    v = m.VERSION
    Ucd(v, parse(Int, split(v, '.')[1]), m.CATEGORY_TABLES, m.BINARY_TABLES, m.SCRIPT_TABLES,
        m.SCRIPT_EXTENSIONS_TABLES, m.SCRIPT_NAMES, m.BINARY_NAMES, m.CASE_FOLDS, m.UPPER_CASES, m.STRING_PROPERTIES,
        Dict{Any,Any}(), ReentrantLock())
end

"The versions of Unicode the package carries."
const V13 = Ucd(Tables13)
const V17 = Ucd(Tables17)
const V18 = Ucd(Tables18)

"""
The Unicode of a version by its major number: 13, 17 or 18. A backreference carries the number of the version it folds
case with (compile.jl), which is never another.
"""
by_major(major::Integer) = major == 13 ? V13 : major == 18 ? V18 : V17

"""
The value of `key` built for the version, made by `make` the first time it is asked for and then kept. The rest of the
engine keeps what it builds from a version's tables here: the case folding classes, the property sets and the
properties of strings.
"""
function built(u::Ucd, key, make)
    lock(u.lock) do
        get!(make, u.built, key)
    end
end

# The Script value Katakana_Or_Hiragana (Hrkt). PropertyValueAliases.txt lists the value, and no code point has it, in
# Script or in Script_Extensions. Scripts.txt has no line for it, so the generated tables do not have it.
const KATAKANA_OR_HIRAGANA = Table(UInt16[], UInt32[])

# The General_Category values that are groups of other values, by the values they gather.
const GROUPS = Dict{String,Vector{String}}(
    "L" => ["Lu", "Ll", "Lt", "Lm", "Lo"],
    "LC" => ["Lu", "Ll", "Lt"],
    "M" => ["Mn", "Mc", "Me"],
    "N" => ["Nd", "Nl", "No"],
    "P" => ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"],
    "S" => ["Sm", "Sc", "Sk", "So"],
    "Z" => ["Zs", "Zl", "Zp"],
    "C" => ["Cc", "Cf", "Cs", "Co", "Cn"],
)

gc(u::Ucd, names...) = union_of((u.category_tables[n] for n in names)...)
# The code points that belong to no script: the unassigned, private use and surrogate code points.
unknown_script(u::Ucd) = built(u, :unknown, () -> gc(u, "Cn", "Co", "Cs"))::Vector{Int}

"""
The ranges of a General_Category value by its short name, such as "Lu" or "L", under a version of Unicode, as a fresh
vector the caller may change, or `nothing` for any other name.
"""
function category(u::Ucd, name::AbstractString)
    group = get(GROUPS, name, nothing)
    group === nothing || return copy(built(u, Symbol("gc_", name), () -> gc(u, group...))::Vector{Int})
    t = get(u.category_tables, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"""
The ranges of a binary property by its canonical name, such as "Alphabetic" or "White_Space", or `nothing` for any
other name. ASCII and Any, which ECMA-262 adds to the properties of Unicode, are not here.
"""
function binary(u::Ucd, name::AbstractString)
    # The code points that have a General_Category other than Cn.
    name == "Assigned" && return copy(built(u, :assigned, () -> complement_of(u.category_tables["Cn"]))::Vector{Int})
    t = get(u.binary_tables, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"The generated table of a binary property, for the callers that test one code point, or `nothing`."
binary_table(u::Ucd, name::AbstractString) = get(u.binary_tables, name, nothing)

"""
The ranges of a Script value by its long name or an alias, such as "Greek" or "Grek", or `nothing` for any other name.
"""
function script(u::Ucd, name::AbstractString)
    name in ("Unknown", "Zzzz") && return copy(unknown_script(u))
    name in ("Katakana_Or_Hiragana", "Hrkt") && return Int[]
    t = get(u.script_tables, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"""
The ranges of a Script_Extensions value by the long name of the script or an alias, or `nothing` for any other name.
"""
function script_extensions(u::Ucd, name::AbstractString)
    name in ("Unknown", "Zzzz") && return copy(unknown_script(u))
    name in ("Katakana_Or_Hiragana", "Hrkt") && return Int[]
    t = get(u.script_extensions_tables, name, nothing)
    t === nothing ? nothing : ranges(t)
end

"The names of every script: each element is the long name of one script followed by its aliases."
script_names(u::Ucd) = u.script_names

"The canonical name of every binary property that has a table, which is every name `binary` knows but Assigned."
binary_names(u::Ucd) = u.binary_names

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
fold(u::Ucd, r::Integer) = fold(u, Int(r))
function fold(u::Ucd, r::Int)
    if r < 0x80
        return 'A' <= Char(r) <= 'Z' ? r + 32 : r
    end
    return map_case(u.case_folds, r)
end

"The simple uppercase mapping of a code point, which is the code point itself when it has none."
to_upper(u::Ucd, r::Integer) = to_upper(u, Int(r))
function to_upper(u::Ucd, r::Int)
    if r < 0x80
        return 'a' <= Char(r) <= 'z' ? r - 32 : r
    end
    return map_case(u.upper_cases, r)
end

"Every code point that `fold` changes, in ascending order."
function folding(u::Ucd)
    dst = Int[]
    for row in u.case_folds
        for offset in 0:Int(row.length)-1
            if offset & row.mask == 0 && row.delta != 0
                push!(dst, row.first + offset)
            end
        end
    end
    return dst
end

end
