# Sets of code points, the classes ECMA-262 defines, and the sets of the Unicode properties (charset.rs).

# The last Unicode code point.
const MAX_RUNE = UCD.MAX_RUNE

"""
An immutable set of code points. The ranges are sorted, inclusive, and neither overlap nor touch. The two words of
`ascii` repeat the membership of the code points below 128 so that the common case is one bit test.
"""
struct CharSet
    ranges::Vector{Int}
    ascii::NTuple{2,UInt64}
end

"Merges inclusive pairs in any order, which may overlap, into sorted pairs that neither overlap nor touch."
function merge_pairs(pairs::Vector{Int})
    idx = sort!(collect(1:(length(pairs)>>1)), alg=Base.Sort.DEFAULT_STABLE, by=i -> pairs[2i-1])
    merged = Int[]
    sizehint!(merged, length(pairs))
    for i in idx
        lo, hi = pairs[2i-1], pairs[2i]
        if !isempty(merged) && lo <= merged[end] + 1
            hi > merged[end] && (merged[end] = hi)
            continue
        end
        push!(merged, lo, hi)
    end
    return merged
end

"The complement of sorted pairs that neither overlap nor touch."
function invert_pairs(merged::Vector{Int})
    inverse = Int[]
    next = 0
    for i in 1:2:length(merged)-1
        lo, hi = merged[i], merged[i+1]
        lo > next && push!(inverse, next, lo - 1)
        next = hi + 1
    end
    next <= MAX_RUNE && push!(inverse, next, MAX_RUNE)
    return inverse
end

"""
Builds a set from inclusive pairs in any order, which may overlap. With `negate` it builds the complement.
"""
function CharSet(pairs::Vector{Int}, negate::Bool=false)
    merged = merge_pairs(pairs)
    negate && (merged = invert_pairs(merged))
    a0, a1 = UInt64(0), UInt64(0)
    for i in 1:2:length(merged)-1
        lo, hi = merged[i], merged[i+1]
        lo >= 128 && break
        for c in lo:min(hi, 127)
            if c < 64
                a0 |= UInt64(1) << c
            else
                a1 |= UInt64(1) << (c - 64)
            end
        end
    end
    return CharSet(merged, (a0, a1))
end

"Whether the set holds the ASCII character `c` (below 128)."
@inline function has_ascii(s::CharSet, c::Integer)
    @inbounds return (s.ascii[((c >> 6) & 1)+1] >> (c & 63)) & 1 != 0
end

"Whether the set holds the code point."
@inline function Base.in(r::Integer, s::CharSet)
    0 <= r < 128 && return has_ascii(s, r)
    ranges = s.ranges
    lo, hi = 0, length(ranges) >> 1
    @inbounds while lo < hi
        mid = (lo + hi) >> 1
        if r > ranges[2mid+2]
            lo = mid + 1
        elseif r < ranges[2mid+1]
            hi = mid
        else
            return true
        end
    end
    return false
end

Base.isempty(s::CharSet) = isempty(s.ranges)

# The classes ECMA-262 defines. \d and \w are ASCII only, \s is WhiteSpace and LineTerminator, and . is everything but
# the four line terminators.
const DIGIT_PAIRS = Int[0x30, 0x39]
const WORD_PAIRS = Int[0x30, 0x39, 0x41, 0x5A, 0x5F, 0x5F, 0x61, 0x7A]
const SPACE_PAIRS = Int[0x9, 0xD, 0x20, 0x20, 0xA0, 0xA0, 0x1680, 0x1680, 0x2000, 0x200A, 0x2028, 0x2029, 0x202F, 0x202F,
    0x205F, 0x205F, 0x3000, 0x3000, 0xFEFF, 0xFEFF]
const LINE_TERMINATOR_PAIRS = Int[0xA, 0xA, 0xD, 0xD, 0x2028, 0x2029]

# Everything but the four line terminators.
const DOT_SET = CharSet(LINE_TERMINATOR_PAIRS, true)

"""
Whether a byte is an ECMA-262 word character. Every word character is ASCII, so a word boundary can be decided from
the units on either side of a position.
"""
@inline is_word_byte(b::Integer) = UInt32('a') <= b <= UInt32('z') || UInt32('A') <= b <= UInt32('Z') ||
                                   UInt32('0') <= b <= UInt32('9') || b == UInt32('_')

const CATEGORY_NAMES = Dict{String,String}()
for (short, names) in (
    "L" => ("Letter",), "Ll" => ("Lowercase_Letter",), "Lu" => ("Uppercase_Letter",), "Lt" => ("Titlecase_Letter",),
    "LC" => ("Cased_Letter",), "Lm" => ("Modifier_Letter",), "Lo" => ("Other_Letter",),
    "M" => ("Mark", "Combining_Mark"), "Mn" => ("Nonspacing_Mark",), "Mc" => ("Spacing_Mark",),
    "Me" => ("Enclosing_Mark",), "N" => ("Number",), "Nd" => ("Decimal_Number", "digit"), "Nl" => ("Letter_Number",),
    "No" => ("Other_Number",), "P" => ("Punctuation", "punct"), "Pc" => ("Connector_Punctuation",),
    "Pd" => ("Dash_Punctuation",), "Ps" => ("Open_Punctuation",), "Pe" => ("Close_Punctuation",),
    "Pi" => ("Initial_Punctuation",), "Pf" => ("Final_Punctuation",), "Po" => ("Other_Punctuation",),
    "S" => ("Symbol",), "Sm" => ("Math_Symbol",), "Sc" => ("Currency_Symbol",), "Sk" => ("Modifier_Symbol",),
    "So" => ("Other_Symbol",), "Z" => ("Separator",), "Zs" => ("Space_Separator",), "Zl" => ("Line_Separator",),
    "Zp" => ("Paragraph_Separator",), "C" => ("Other",), "Cc" => ("Control", "cntrl"), "Cf" => ("Format",),
    "Cs" => ("Surrogate",), "Co" => ("Private_Use",), "Cn" => ("Unassigned",))
    CATEGORY_NAMES[short] = short
    for n in names
        CATEGORY_NAMES[n] = short
    end
end

"""
The short name of a General_Category value, from its long name, an alias or the short name itself, and "" for any
other name.
"""
category_name(value::AbstractString) = get(CATEGORY_NAMES, value, "")

const BINARY_NAMES = Dict{String,String}()
for (canonical, aliases) in (
    "ASCII" => (), "ASCII_Hex_Digit" => ("AHex",), "Alphabetic" => ("Alpha",), "Any" => (), "Assigned" => (),
    "Bidi_Control" => ("Bidi_C",), "Bidi_Mirrored" => ("Bidi_M",), "Case_Ignorable" => ("CI",), "Cased" => (),
    "Changes_When_Casefolded" => ("CWCF",), "Changes_When_Casemapped" => ("CWCM",),
    "Changes_When_Lowercased" => ("CWL",), "Changes_When_NFKC_Casefolded" => ("CWKCF",),
    "Changes_When_Titlecased" => ("CWT",), "Changes_When_Uppercased" => ("CWU",), "Dash" => (),
    "Default_Ignorable_Code_Point" => ("DI",), "Deprecated" => ("Dep",), "Diacritic" => ("Dia",), "Emoji" => (),
    "Emoji_Component" => ("EComp",), "Emoji_Modifier" => ("EMod",), "Emoji_Modifier_Base" => ("EBase",),
    "Emoji_Presentation" => ("EPres",), "Extended_Pictographic" => ("ExtPict",), "Extender" => ("Ext",),
    "Grapheme_Base" => ("Gr_Base",), "Grapheme_Extend" => ("Gr_Ext",), "Hex_Digit" => ("Hex",),
    "IDS_Binary_Operator" => ("IDSB",), "IDS_Trinary_Operator" => ("IDST",), "ID_Continue" => ("IDC",),
    "ID_Start" => ("IDS",), "Ideographic" => ("Ideo",), "Join_Control" => ("Join_C",),
    "Logical_Order_Exception" => ("LOE",), "Lowercase" => ("Lower",), "Math" => (),
    "Noncharacter_Code_Point" => ("NChar",), "Pattern_Syntax" => ("Pat_Syn",), "Pattern_White_Space" => ("Pat_WS",),
    "Quotation_Mark" => ("QMark",), "Radical" => (), "Regional_Indicator" => ("RI",),
    "Sentence_Terminal" => ("STerm",), "Soft_Dotted" => ("SD",), "Terminal_Punctuation" => ("Term",),
    "Unified_Ideograph" => ("UIdeo",), "Uppercase" => ("Upper",), "Variation_Selector" => ("VS",),
    "White_Space" => ("space",), "XID_Continue" => ("XIDC",), "XID_Start" => ("XIDS",))
    BINARY_NAMES[canonical] = canonical
    for a in aliases
        BINARY_NAMES[a] = canonical
    end
end

"""
The canonical name of a binary property ECMA-262 lists, from the name or an alias, and "" for any other name.
"""
binary_name(name::AbstractString) = get(BINARY_NAMES, name, "")

# The sets already built for property expressions. A property set can have hundreds of ranges, and schemas tend to
# repeat the same few. Only an expression ECMA-262 defines is kept, and those are a fixed few hundred, so the cache is
# bounded.
const PROPERTY_CACHE = Dict{String,CharSet}()
const PROPERTY_LOCK = ReentrantLock()

"""
The set of the expression between the braces of \\p{...}, or `nothing` for a name or value that ECMA-262 does not
define.
"""
function property_set(expr::AbstractString)
    expr = String(expr)
    lock(PROPERTY_LOCK) do
        cached = get(PROPERTY_CACHE, expr, nothing)
        cached === nothing || return cached
        pairs = property_pairs(expr)
        pairs === nothing && return nothing
        set = CharSet(pairs)
        PROPERTY_CACHE[expr] = set
        return set
    end
end

"""
The ranges of a property expression, or `nothing`. Every range comes from the tables of UCD, which hold one fixed
version of Unicode, so the answer does not depend on the Julia release.
"""
function property_pairs(expr::String)
    eq = findfirst('=', expr)
    if eq !== nothing
        name, value = expr[1:eq-1], expr[eq+1:end]
        name in ("General_Category", "gc") && return category_pairs(value)
        name in ("Script", "sc") && return UCD.script(value)
        name in ("Script_Extensions", "scx") && return UCD.script_extensions(value)
        return nothing
    end
    pairs = category_pairs(expr)
    pairs === nothing || return pairs
    canonical = binary_name(expr)
    canonical == "" && return nothing
    canonical == "ASCII" && return Int[0, 0x7F]
    canonical == "Any" && return Int[0, MAX_RUNE]
    return UCD.binary(canonical)
end

function category_pairs(value::AbstractString)
    name = category_name(value)
    name == "" ? nothing : UCD.category(name)
end

"The code points in both sets."
function Base.intersect(s::CharSet, other::CharSet)
    a, b = s.ranges, other.ranges
    i, j = 1, 1
    pairs = Int[]
    while i < length(a) && j < length(b)
        lo, hi = max(a[i], b[j]), min(a[i+1], b[j+1])
        lo <= hi && push!(pairs, lo, hi)
        if a[i+1] < b[j+1]
            i += 2
        else
            j += 2
        end
    end
    return CharSet(pairs)
end

"The code points of this set that are not in the other."
subtract(s::CharSet, other::CharSet) = intersect(s, CharSet(other.ranges, true))

"The code points of either set."
Base.union(s::CharSet, other::CharSet) = CharSet(vcat(s.ranges, other.ranges))

"The code points not in the set."
complement(s::CharSet) = CharSet(s.ranges, true)

"""
The value of a property of strings, which only the v flag can name: its single code points and its sequences.
"""
struct StringProperty
    set::CharSet
    strings::Vector{Vector{Int}}
end

include("strings_gen.jl")

hex_rune(s::AbstractString) = parse(Int, s; base=16)

const ALL_STRING_PROPERTIES = Ref{Vector{StringProperty}}()
const STRING_PROPERTIES_LOCK = ReentrantLock()

function all_string_properties()
    lock(STRING_PROPERTIES_LOCK) do
        isassigned(ALL_STRING_PROPERTIES) && return ALL_STRING_PROPERTIES[]
        all = StringProperty[]
        union = Int[]
        every = Vector{Int}[]
        for row in STRING_PROPERTIES
            pairs = Int[]
            for item in split(row[2])
                parts = split(item, "..")
                lo = parts[1]
                hi = length(parts) == 2 ? parts[2] : lo
                push!(pairs, hex_rune(lo), hex_rune(hi))
            end
            sequences = Vector{Int}[]
            for s in split(row[3], ';')
                isempty(s) && continue
                push!(sequences, [hex_rune(c) for c in split(s)])
            end
            append!(union, pairs)
            append!(every, sequences)
            push!(all, StringProperty(CharSet(pairs), sequences))
        end
        push!(all, StringProperty(CharSet(union), every))
        ALL_STRING_PROPERTIES[] = all
        return all
    end
end

"The property of strings of the name (RGI_Emoji and the six it is the union of), or `nothing`."
function string_property_of(name::AbstractString)
    all = all_string_properties()
    name == "RGI_Emoji" && return all[end]
    for (k, row) in enumerate(STRING_PROPERTIES)
        row[1] == name && return all[k]
    end
    return nothing
end

"""
The generated table of a binary property the engine relies on. Its absence means the generated tables are broken, so
it throws.
"""
function must_binary_table(name::AbstractString)
    t = UCD.binary_table(name)
    t === nothing && error("the Unicode tables have no " * name)
    return t
end
