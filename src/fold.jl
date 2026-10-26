# Case-insensitive matching (fold.rs).
#
# It exists only inside a modifier group such as (?i:...), or under the i flag. ECMA-262 defines it through a
# Canonicalize function. Two characters match when they canonicalize to the same character. The function differs
# between the two grammars. With the u flag it is Unicode simple case folding. With no flag it is the single
# character uppercase mapping of a UTF-16 code unit, which never maps a character outside ASCII into ASCII.
#
# The parser applies the equivalence to every literal and class as it reads them, so a case-insensitive group is
# matched with plain classes. Only a backreference needs the function when matching.
#
# The folding and the uppercase mapping come from the tables of UCD, never from Julia's own, so a pattern matches the
# same texts whichever Julia runs it.

# The characters of the Basic Multilingual Plane whose uppercase form is more than one character. Canonicalize leaves
# them alone.
const MULTI_UPPER = CharSet(Int[
    0xDF, 0xDF, 0x149, 0x149, 0x1F0, 0x1F0, 0x390, 0x390, 0x3B0, 0x3B0, 0x587, 0x587, 0x1E96, 0x1E9A, 0x1F50,
    0x1F50, 0x1F52, 0x1F52, 0x1F54, 0x1F54, 0x1F56, 0x1F56, 0x1F80, 0x1FAF, 0x1FB2, 0x1FB4, 0x1FB6, 0x1FB7,
    0x1FBC, 0x1FBC, 0x1FC2, 0x1FC4, 0x1FC6, 0x1FC7, 0x1FCC, 0x1FCC, 0x1FD2, 0x1FD3, 0x1FD6, 0x1FD7, 0x1FE2,
    0x1FE4, 0x1FE6, 0x1FE7, 0x1FF2, 0x1FF4, 0x1FF6, 0x1FF7, 0x1FFC, 0x1FFC, 0xFB00, 0xFB06, 0xFB13, 0xFB17,
])

"The Canonicalize function of ECMA-262 for case-insensitive matching."
function canonicalize(r::Int, unicode_mode::Bool)
    # Every character of a simple case folding class folds to the same character.
    unicode_mode && return UCD.fold(r)
    # A character beyond the Basic Multilingual Plane is two code units, and neither has an uppercase form.
    (r > 0xFFFF || r in MULTI_UPPER) && return r
    upper = UCD.to_upper(r)
    (r >= 128 && upper < 128 || upper > 0xFFFF) && return r
    return upper
end

"""
The characters that are equivalent to some other character, each with all the members of its equivalence class:
`points` sorted, and for each its class in `classes`.
"""
struct FoldTable
    points::Vector{Int}
    class_of::Vector{Int}
    classes::Vector{Vector{Int}}
end

function FoldTable(classes::Dict{Int,Vector{Int}})
    points = Int[]
    by_member = Dict{Int,Int}()
    kept = Vector{Int}[]
    for class in values(classes)
        length(class) < 2 && continue
        push!(kept, class)
        for member in class
            push!(points, member)
            by_member[member] = length(kept)
        end
    end
    sort!(points)
    return FoldTable(points, [by_member[p] for p in points], kept)
end

const FOLD_TABLES = Dict{Bool,FoldTable}()
const FOLD_LOCK = ReentrantLock()

function build_fold_table(unicode_mode::Bool)
    classes = Dict{Int,Vector{Int}}()
    if unicode_mode
        # A class is a character that others fold to, with those others.
        for r in UCD.folding()
            key = UCD.fold(r)
            push!(get!(() -> [key], classes, key), r)
        end
    else
        for r in 0:0xFFFF
            push!(get!(Vector{Int}, classes, canonicalize(r, false)), r)
        end
    end
    return FoldTable(classes)
end

"""
The table of the grammar in use. It is built on first use, which only a pattern with a case-insensitive group
reaches.
"""
fold_classes(unicode_mode::Bool) = lock(() -> get!(() -> build_fold_table(unicode_mode), FOLD_TABLES, unicode_mode), FOLD_LOCK)

"""
The set of every character equivalent to some member of the set, and the number of characters with a case variant
that the set holds, which is the work it did.
"""
function fold_closure(set::CharSet, unicode_mode::Bool)
    table = fold_classes(unicode_mode)
    extra = Int[]
    variants = 0
    points = table.points
    for i in 1:2:length(set.ranges)-1
        lo, hi = set.ranges[i], set.ranges[i+1]
        k = searchsortedfirst(points, lo)
        while k <= length(points) && points[k] <= hi
            variants += 1
            for member in table.classes[table.class_of[k]]
                member in set || push!(extra, member, member)
            end
            k += 1
        end
    end
    isempty(extra) && return set, variants
    append!(extra, set.ranges)
    return CharSet(extra), variants
end

# With the u flag and case-insensitive matching, the characters \w and \b count as word characters: the ASCII ones
# and the two characters that fold to an ASCII letter (U+017F, the long s, and U+212A, the Kelvin sign).
const FOLD_WORD_PAIRS = Int[0x30, 0x39, 0x41, 0x5A, 0x5F, 0x5F, 0x61, 0x7A, 0x17F, 0x17F, 0x212A, 0x212A]
const FOLD_WORD_SET = CharSet(FOLD_WORD_PAIRS)
const NOT_FOLD_WORD_SET = CharSet(FOLD_WORD_PAIRS, true)

is_fold_word_rune(r::Integer) = 0 <= r < 128 && is_word_byte(r) || r == 0x17F || r == 0x212A
