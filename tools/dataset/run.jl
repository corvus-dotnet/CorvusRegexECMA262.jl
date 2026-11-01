# Runs the engine over the ECMA-262 regular expression test data (github.com/corvus-dotnet/ecma262-regex-test-data), as
# the runner of the Rust crate does (tools/src/bin/dataset.rs there), with the same judging rules.
#
#   julia -t 4 --project=. tools/dataset/run.jl <data directory> <wrong-cases output file> [file filter] [utf16|utf8|both] [--compliance <file>]
#       [--edition current|es2020] [--unicode 13|17|18|latest]
#
# Each record is asked about under each grammar V8 found it valid in: the record's flags with u added (the unicode
# answers), the record's flags alone (the legacy answers) and, in the file that has them, the flags with v added (the
# unicode_sets answers). A text is matched as UTF-16 and as UTF-8; a text with a lone surrogate has no UTF-8 form and is
# matched as UTF-16 alone. Records marked v8_deviation are left out. A pattern is UTF-8, so a lone surrogate in one is
# read as U+FFFD, as the Rust runner reads it. captures.jsonl is judged on exec, the global search, the sticky flag,
# replace and split. ill-formed-utf8.jsonl holds bytes that are not UTF-8, each one answer over UTF-8 under each grammar
# the pattern is valid in, whose right answer is a refusal: an EncodingError.
#
# exec/test262.jsonl, the exec calls of test262 (in a directory of its own), is judged last: each call one exec with the
# record's flags from its lastIndex, right when the positions of the match and of every group, the named groups and,
# with g or y, the lastIndex after are V8's; one answer over UTF-16 and, when the text holds no lone surrogate and
# lastIndex is not between the halves of a pair, one over UTF-8 with positions in bytes.
#
# With --edition and --unicode the engine reads every pattern with that edition's grammar and that version's tables, and
# the data is the data as node edition.js apply or node unicode.js apply writes it for them.
#
# With --compliance <file>, the engine's compliance object is written to the file, as the benchmark page reads it
# (docs/implementing-a-source.md in corvus-regex-ecma262-benchmarks): the counts, this runner and the calls it makes in
# each encoding, and what it leaves out, which for this library is nothing.

using CorvusRegexECMA262
const C = CorvusRegexECMA262

const LIMIT = 2.0
const REPLACEMENT = "<\$&|\$1|\$2|\$10|\$<a>|\$\$|\$`|\$'>"
const REPLACEMENT16 = transcode(UInt16, REPLACEMENT)
# The file of the exec calls of test262, in a directory of its own.
const EXEC = "exec/test262.jsonl"

mutable struct Counts
    right::Int
    wrong::Int
    refused::Int
    accepted::Int
    limited::Int
    errors::Int
end

Counts() = Counts(0, 0, 0, 0, 0, 0)

function add!(c::Counts, o::Counts)
    c.right += o.right
    c.wrong += o.wrong
    c.refused += o.refused
    c.accepted += o.accepted
    c.limited += o.limited
    c.errors += o.errors
end

const AS_UTF16 = Ref(true)
const AS_UTF8 = Ref(true)

# Units of text.

function has_lone_surrogate(s::Vector{UInt16})
    k = 1
    while k <= length(s)
        u = s[k]
        if 0xD800 <= u <= 0xDBFF
            if k < length(s) && 0xDC00 <= s[k+1] <= 0xDFFF
                k += 2
                continue
            end
            return true
        end
        0xDC00 <= u <= 0xDFFF && return true
        k += 1
    end
    return false
end

"The UTF-8 of UTF-16 units, each lone surrogate written as U+FFFD."
function lossy(s::Vector{UInt16})
    io = IOBuffer()
    k = 1
    while k <= length(s)
        u = s[k]
        if 0xD800 <= u <= 0xDBFF && k < length(s) && 0xDC00 <= s[k+1] <= 0xDFFF
            print(io, Char(0x10000 + (Int(u) - 0xD800) << 10 + (Int(s[k+1]) - 0xDC00)))
            k += 2
            continue
        end
        print(io, 0xD800 <= u <= 0xDFFF ? '�' : Char(u))
        k += 1
    end
    return String(take!(io))
end

function escape(units::Vector{UInt16})
    io = IOBuffer()
    for u in units
        if 0x20 <= u < 0x7f && u != UInt16('\\')
            print(io, Char(u))
        else
            print(io, "\\u", string(u, base=16, pad=4))
        end
    end
    return String(take!(io))
end

str(v) = v isa Vector{UInt16} ? v : UInt16[]
get_(o, name) = o isa Dict{String,Any} ? get(o, name, nothing) : nothing
array(o) = o isa Vector{Any} ? o : nothing

struct Mode
    add::String
    answers::String
    valid::Any
end

"The modes a record is asked about: the flags to add, the name of the answers, and whether V8 found it valid."
function modes(r)
    valid = get_(r, "valid")
    ms = [Mode("u", "unicode", get_(valid, "unicode")), Mode("", "legacy", get_(valid, "legacy"))]
    v = get_(valid, "unicode_sets")
    v === nothing || push!(ms, Mode("v", "unicode_sets", v))
    return ms
end

first_line(s::AbstractString) = (k = findfirst('\n', s); k === nothing ? s : s[1:prevind(s, k)])

# The edition and the version of Unicode the engine reads every pattern with (--edition, --unicode).
const EDITION = Ref(:current)
const UNICODE_VERSION = Ref{Union{Symbol,Int}}(:default)

compile(pattern::String, flags::String) =
    EcmaRegex(pattern, flags; match_timeout=LIMIT, edition=EDITION[], unicode_version=UNICODE_VERSION[])

"Which limit a match reached, or `nothing` when the error is not a limit."
limit_kind(e) = e isa C.MatchTimeoutError ? "time" : e isa C.MatchMemoryError ? "memory" : nothing

# The answers of the grammar-only reader (isvalid_pattern) that agree with V8's, and those that do not.
const READER_RIGHT = Threads.Atomic{Int}(0)
const READER_WRONG = Threads.Atomic{Int}(0)

"""
Asks the grammar-only reader whether the pattern is valid in each grammar of the record, as V8 answered. It reads no
limit of size, so its answer is the grammar's for a pattern of any size.
"""
function judge_reader(name::String, r, pattern::String, wrong::Vector{String})
    flags = lossy(str(get_(r, "flags")))
    for m in modes(r)
        mode_flags = flags * m.add
        expected_valid = m.valid == true
        valid = C.isvalid_pattern(pattern, mode_flags; edition=EDITION[], unicode_version=UNICODE_VERSION[])
        if valid == expected_valid
            Threads.atomic_add!(READER_RIGHT, 1)
        else
            Threads.atomic_add!(READER_WRONG, 1)
            push!(wrong, "READER\t" * name * "\t/" * escape(transcode(UInt16, pattern)) * "/" * mode_flags *
                         "\tV8 says " * (expected_valid ? "valid" : "not valid"))
        end
    end
end

function judge_record(name::String, r, c::Counts, wrong::Vector{String})
    pattern = lossy(str(get_(r, "pattern")))
    name == EXEC || judge_reader(name, r, pattern, wrong)
    if name == EXEC
        judge_exec(r, pattern, c, wrong)
    elseif name == "captures.jsonl"
        AS_UTF16[] && judge_captures(r, pattern, c, wrong)
    elseif name == "ill-formed-utf8.jsonl"
        AS_UTF8[] && judge_ill_formed(r, pattern, c, wrong)
    else
        judge_tests(name, r, pattern, c, wrong)
    end
end

function judge_ill_formed(r, pattern::String, c::Counts, wrong::Vector{String})
    name = "ill-formed-utf8.jsonl"
    flags = lossy(str(get_(r, "flags")))
    shown = escape(transcode(UInt16, pattern))
    for m in modes(r)
        mode_flags = flags * m.add
        expected_valid = m.valid == true
        head = name * "\t/" * shown * "/" * mode_flags
        re = try
            compile(pattern, mode_flags)
        catch e
            if expected_valid
                c.refused += 1
                push!(wrong, "REFUSED\t" * head * "\t" * first_line(sprint(showerror, e)))
            end
            continue
        end
        if !expected_valid
            c.accepted += 1
            push!(wrong, "ACCEPTED-INVALID\t" * head)
            continue
        end
        for t in something(array(get_(r, "tests")), [])
            hex = lossy(str(get_(t, "bytes")))
            bytes = [parse(UInt8, hex[2k-1:2k]; base=16) for k in 1:length(hex)÷2]
            try
                got = occursin(re, String(bytes))
                c.wrong += 1
                push!(wrong, "WRONG\t$head\t$hex\tutf8\tread as UTF-8 ($got), not refused")
            catch e
                if limit_kind(e) !== nothing
                    c.limited += 1
                    push!(wrong, "LIMIT\t$head\t$hex\tutf8")
                elseif e isa C.EncodingError
                    c.right += 1
                else
                    c.errors += 1
                    push!(wrong, "ERROR\t$head\t$hex\tutf8\t" * sprint(showerror, e))
                end
            end
        end
    end
end

function judge_tests(name::String, r, pattern::String, c::Counts, wrong::Vector{String})
    flags = lossy(str(get_(r, "flags")))
    shown = escape(transcode(UInt16, pattern))
    for m in modes(r)
        mode_flags = flags * m.add
        expected_valid = m.valid == true
        re = try
            compile(pattern, mode_flags)
        catch e
            message = if e isa C.InvalidPatternError
                "PARSE: " * sprint(showerror, e)
            elseif e isa C.TooLargeError
                "TOO-LARGE: " * sprint(showerror, e)
            elseif e isa C.FlagsError
                # The flags of a grammar the edition does not have (the v flag of ECMAScript 2020): a refusal.
                "FLAGS: " * sprint(showerror, e)
            else
                c.errors += 1
                "ERROR: " * sprint(showerror, e)
            end
            if expected_valid
                c.refused += 1
                push!(wrong, "REFUSED\t" * name * "\t/" * shown * "/" * mode_flags * "\t" * first_line(message))
            end
            continue
        end
        if !expected_valid
            c.accepted += 1
            push!(wrong, "ACCEPTED-INVALID\t" * name * "\t/" * shown * "/" * mode_flags)
            continue
        end
        for t in something(array(get_(r, "tests")), [])
            expected = get_(t, m.answers)
            expected isa Bool || continue
            text = str(get_(t, "text"))
            if AS_UTF16[]
                got, err = attempt(() -> occursin(re, text))
                check(name, shown, mode_flags, text, "utf16", expected, got, err, c, wrong)
            end
            if AS_UTF8[] && !has_lone_surrogate(text)
                got, err = attempt(() -> occursin(re, lossy(text)))
                check(name, shown, mode_flags, text, "utf8", expected, got, err, c, wrong)
            end
        end
    end
end

"The value of f(), and the error it threw or nothing."
function attempt(f)
    try
        return f(), nothing
    catch e
        return nothing, e
    end
end

function check(name, shown, mode_flags, text, encoding, expected, got, err, c::Counts, wrong::Vector{String})
    where_ = name * "\t/" * shown * "/" * mode_flags * "\t" * escape(text) * "\t" * encoding
    if err === nothing && got == expected
        c.right += 1
    elseif err === nothing
        c.wrong += 1
        push!(wrong, "WRONG\t$where_\texpected $expected")
    elseif limit_kind(err) !== nothing
        c.limited += 1
        push!(wrong, "LIMIT\t$where_\t" * limit_kind(err))
    else
        c.errors += 1
        push!(wrong, "ERROR\t$where_\t" * sprint(showerror, err))
    end
end

# exec/test262.jsonl

"""
A call's lastIndex. Past the end of the text exec gives null; test262 sets it as far as 2^53 - 1 and Number.MAX_VALUE,
so anything past the end reads as the text's length plus one.
"""
function last_index_of(t, len::Int)
    v = get_(t, "lastIndex")::Float64
    return v > len ? len + 1 : Int(v)
end

"Whether a position is between the halves of a surrogate pair, where UTF-8 has no position."
inside_pair(s::Vector{UInt16}, at::Int) = 0 < at < length(s) && 0xDC00 <= s[at+1] <= 0xDFFF && 0xD800 <= s[at] <= 0xDBFF

"""
Compares a span of the answer (null, or [start, end]) with group g of the engine's slots (-1 for no group).
"""
function same_span(e, slots::Vector{Int}, g::Int, at)
    b = array(e)
    took = g >= 0 && slots[2g+1] >= 0
    b === nothing && return !took
    return took && at(Int(b[1])) == slots[2g+1] && at(Int(b[2])) == slots[2g+2]
end

"The group with the name that took part in the match, or -1."
function named_group(re::EcmaRegex, slots::Vector{Int}, name::String)
    for g in C.group_index(re, name)
        slots[2g+1] >= 0 && return g
    end
    return -1
end

"""
Whether an engine's match (nothing for none) is the call's answer: both null, or the same groups, the same named groups
(present exactly when the pattern has names) and, with g or y, a lastIndex after at the match's end.
"""
function same_exec(answer, re::EcmaRegex, slots, names::Vector{String}, carries::Bool, at)
    (answer === nothing || slots === nothing) && return answer === nothing && slots === nothing
    captures = array(get_(answer, "captures"))
    (captures === nothing || length(captures) != length(slots) ÷ 2) && return false
    for g in 0:length(captures)-1
        same_span(captures[g+1], slots, g, at) || return false
    end
    groups = get_(answer, "groups")
    if !(groups isa Dict{String,Any})
        isempty(names) || return false
    else
        length(groups) != length(names) && return false
        for (name, v) in groups
            (name in names && same_span(v, slots, named_group(re, slots, name), at)) || return false
        end
    end
    return !carries || at(Int(get_(answer, "lastIndex")::Float64)) == slots[2]
end

function count_exec(c::Counts, wrong::Vector{String}, where_, encoding, ok::Bool, err)
    if err !== nothing
        c.limited += 1
        push!(wrong, "LIMIT\t$EXEC\t$where_\t$encoding")
    elseif ok
        c.right += 1
    else
        c.wrong += 1
        push!(wrong, "WRONG\t$EXEC\t$where_\t$encoding")
    end
end

"The distinct names of the pattern's groups."
group_name_list(re::EcmaRegex) = unique(String[n for n in C.group_names(re) if n !== nothing])

"The slots of the first match at or after `start` of a text (0-based, in its units), or nothing."
function submatch(re::EcmaRegex, input, start::Int, sticky::Bool=re.flags.sticky)
    slots = Vector{Int}(undef, 2 * (C.group_count(re) + 1))
    C.exec_slots(re, input, start, sticky, slots)[3] ? slots : nothing
end

"""
Judges a record of exec/test262.jsonl: the pattern with its own flags (g, y and d among them), from each lastIndex.
"""
function judge_exec(r, pattern::String, c::Counts, wrong::Vector{String})
    flags = lossy(str(get_(r, "flags")))
    shown = escape(transcode(UInt16, pattern))
    re = try
        compile(pattern, flags)
    catch e
        c.refused += 1
        push!(wrong, "REFUSED\t$EXEC\t/$shown/$flags\t" * first_line(sprint(showerror, e)))
        return
    end
    carries = occursin('g', flags) || occursin('y', flags)
    names = group_name_list(re)
    for t in something(array(get_(r, "tests")), [])
        get_(t, "v8_deviation") == true && continue
        text = str(get_(t, "text"))
        start = carries ? last_index_of(t, length(text)) : 0
        answer = get_(t, "answer")
        li = get_(t, "lastIndex")
        where_ = "/$shown/$flags\t$(escape(text))\t$(isinteger(li) && abs(li) < 1e15 ? Int(li) : li)"
        if AS_UTF16[]
            slots, err = start <= length(text) ? attempt(() -> submatch(re, text, start)) : (nothing, nothing)
            count_exec(c, wrong, where_, "utf16", err === nothing && same_exec(answer, re, slots, names, carries, identity), err)
        end
        if AS_UTF8[] && !has_lone_surrogate(text) && !inside_pair(text, start)
            byte_at = byte_offsets(text)
            u8 = codeunits(lossy(text))
            slots, err = start <= length(text) ? attempt(() -> submatch(re, u8, byte_at[start+1])) : (nothing, nothing)
            to_byte = k -> byte_at[k+1]
            count_exec(c, wrong, where_, "utf8", err === nothing && same_exec(answer, re, slots, names, carries, to_byte), err)
        end
    end
end

# captures.jsonl

"The groups of an exec answer: nothing for no match, else the bounds of each group, nothing for one not taking part."
function exec_of(e)
    groups = array(e)
    groups === nothing && return nothing
    return [array(g) === nothing ? nothing : (Int(g[1]), Int(g[2])) for g in groups]
end

"For each UTF-16 index of a text (and the index past its end), the byte offset in UTF-8."
function byte_offsets(s::Vector{UInt16})
    at = zeros(Int, length(s) + 1)
    b = 0
    k = 1
    while k <= length(s)
        at[k] = b
        c = s[k]
        if 0xD800 <= c <= 0xDBFF && k < length(s) && 0xDC00 <= s[k+1] <= 0xDFFF
            at[k+1] = b + 2
            b += 4
            k += 2
            continue
        end
        b += c < 0x80 ? 1 : c < 0x800 ? 2 : 3
        k += 1
    end
    at[end] = b
    return at
end

"The bounds of each group of slots, nothing for one not taking part, or nothing for no match."
function groups_of(slots)
    slots === nothing && return nothing
    return [slots[2g+1] >= 0 ? (slots[2g+1], slots[2g+2]) : nothing for g in 0:length(slots)÷2-1]
end

function same_slots(expected, got, at)
    (expected === nothing || got === nothing) && return expected === nothing && got === nothing
    length(expected) != length(got) && return false
    for k in eachindex(expected)
        a, b = expected[k], got[k]
        if a === nothing || b === nothing
            (a === nothing) != (b === nothing) && return false
        elseif at(a[1]) != b[1] || at(a[2]) != b[2]
            return false
        end
    end
    return true
end

"""
Compares a global search with the data's, which keeps the first twenty matches only: found has at most 21, and one more
than the data has is right only when the data kept twenty.
"""
function same_all(all, found, at)
    for (n, slots) in enumerate(found)
        n > length(all) && return length(all) == 20
        same_slots(all[n], groups_of(slots), at) || return false
    end
    return !((length(all) < 20 && length(found) != length(all)) || (length(all) == 20 && length(found) < 20))
end

"same_all on the bounds of the whole match alone."
function same_all_bounds(all, found, at)
    for (n, b) in enumerate(found)
        n > length(all) && return length(all) == 20
        e = all[n]
        (e === nothing || at(e[1][1]) != b[1] || at(e[1][2]) != b[2]) && return false
    end
    return !((length(all) < 20 && length(found) != length(all)) || (length(all) == 20 && length(found) < 20))
end

function same_split16(expected, text::Vector{UInt16}, got::Vector{Tuple{Int,Int}})
    e = array(expected)
    length(e) != length(got) && return false
    for k in eachindex(e)
        from, to = got[k]
        if e[k] === nothing
            from >= 0 && return false
        else
            (from >= 0 && str(e[k]) == text[from+1:to]) || return false
        end
    end
    return true
end

"The text with the first match, or every match with `all`, replaced, as String.prototype.replace replaces it."
function replaced(re::EcmaRegex, input, template, all::Bool)
    out = C.replace_units(re, input, template, all)
    return out === nothing ? collect(input) : out
end

function judge_captures(r, pattern::String, c::Counts, wrong::Vector{String})
    flags = lossy(str(get_(r, "flags")))
    valid = get_(r, "valid")
    shown = escape(transcode(UInt16, pattern))
    cache = Dict{String,Union{Nothing,EcmaRegex}}()
    make(f) = get!(cache, f) do
        try
            compile(pattern, f)
        catch
            nothing
        end
    end
    # A grammar the data finds the pattern not valid in, as an overlay may, must be refused here too.
    for m in ("unicode", "legacy")
        mode_flags = m == "unicode" ? flags * "u" : flags
        if get_(valid, m) == false && make(mode_flags) !== nothing
            c.accepted += 1
            push!(wrong, "ACCEPTED-INVALID\tcaptures.jsonl\t/" * shown * "/" * mode_flags)
        end
    end
    for t in something(array(get_(r, "tests")), [])
        get_(t, "v8_deviation") == true && continue
        text = str(get_(t, "text"))
        for m in ("unicode", "legacy")
            get_(valid, m) == true || continue
            a = get_(t, m)
            a === nothing && continue
            mode_flags = m == "unicode" ? flags * "u" : flags
            where_ = "/" * shown * "/" * mode_flags * "\t" * escape(text)
            re, g, y = make(mode_flags), make(mode_flags * "g"), make(mode_flags * "y")
            if re === nothing || g === nothing || y === nothing
                c.refused += 1
                push!(wrong, "REFUSED\tcaptures.jsonl\t" * where_)
                continue
            end
            lone = has_lone_surrogate(text)
            u8 = lone ? UInt8[] : Vector{UInt8}(codeunits(lossy(text)))
            byte_at = lone ? Int[] : byte_offsets(text)
            to_byte = k -> byte_at[k+1]
            v(what, ok, err) =
                if err !== nothing
                    c.limited += 1
                    push!(wrong, "LIMIT\tcaptures.jsonl\t$where_\t$what")
                elseif ok
                    c.right += 1
                else
                    c.wrong += 1
                    push!(wrong, "WRONG\tcaptures.jsonl\t$where_\t$what")
                end

            # exec
            expected = exec_of(get_(a, "exec"))
            got, err = attempt(() -> submatch(re, text, 0))
            if err !== nothing
                c.limited += 1
                push!(wrong, "LIMIT\tcaptures.jsonl\t" * where_)
                continue
            end
            v("exec", same_slots(expected, groups_of(got), identity), nothing)
            if !lone
                got, err = attempt(() -> submatch(re, u8, 0))
                v("exec-utf8", err === nothing && same_slots(expected, groups_of(got), to_byte), err)
            end

            # all
            all = [exec_of(e) for e in something(array(get_(a, "all")), [])]
            found, err = attempt(() -> C.find_all(g, text, 21, true))
            v("all", err === nothing && same_all(all, found, identity), err)
            if !lone
                found, err = attempt(() -> C.find_all(g, u8, 21, false))
                v("all-utf8", err === nothing && same_all_bounds(all, found, to_byte), err)
            end

            # sticky at 1
            if !isempty(text)
                sticky = exec_of(get_(a, "sticky"))
                got, err = attempt(() -> submatch(y, text, 1))
                v("sticky", err === nothing && same_slots(sticky, groups_of(got), identity), err)
                if !lone && !(0xD800 <= text[1] <= 0xDBFF)
                    got, err = attempt(() -> submatch(y, u8, byte_at[2]))
                    v("sticky-utf8", err === nothing && same_slots(sticky, groups_of(got), to_byte), err)
                end
            end

            # replace
            replace1, replace_all = str(get_(a, "replace")), str(get_(a, "replaceAll"))
            out, err = attempt(() -> replaced(re, text, REPLACEMENT16, false))
            v("replace", err === nothing && out == replace1, err)
            out, err = attempt(() -> replaced(g, text, REPLACEMENT16, true))
            v("replaceAll", err === nothing && out == replace_all, err)
            if !lone
                # Over UTF-8 a half character is written as U+FFFD, which is what a lossy conversion of V8's answer
                # writes for it.
                out, err = attempt(() -> replaced(re, u8, codeunits(REPLACEMENT), false))
                v("replace-utf8", err === nothing && String(out) == lossy(replace1), err)
                out, err = attempt(() -> replaced(g, u8, codeunits(REPLACEMENT), true))
                v("replaceAll-utf8", err === nothing && String(out) == lossy(replace_all), err)
            end

            # split
            pieces, err = attempt(() -> C.split_units(re, text, -1))
            v("split", err === nothing && same_split16(get_(a, "split"), text, pieces), err)
            pieces, err = attempt(() -> C.split_units(re, text, 3))
            v("split3", err === nothing && same_split16(get_(a, "split3"), text, pieces), err)
        end
    end
end

# A small JSON reader whose strings are UTF-16 units (Vector{UInt16}) and keep lone surrogates.

mutable struct Reader
    s::Vector{UInt8}
    i::Int
end

function parse_json(line::String)
    r = Reader(Vector{UInt8}(codeunits(line)), 1)
    v = value!(r)
    space!(r)
    r.i == length(r.s) + 1 || error("unexpected text at $(r.i)")
    return v
end

function space!(r::Reader)
    while r.i <= length(r.s) && r.s[r.i] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        r.i += 1
    end
end

function expect!(r::Reader, c::Char)
    r.s[r.i] == UInt8(c) || error("expected $c at $(r.i)")
    r.i += 1
end

function value!(r::Reader)
    space!(r)
    c = Char(r.s[r.i])
    if c == '{'
        r.i += 1
        m = Dict{String,Any}()
        space!(r)
        if r.s[r.i] == UInt8('}')
            r.i += 1
            return m
        end
        while true
            space!(r)
            key = lossy(string!(r))
            space!(r)
            expect!(r, ':')
            m[key] = value!(r)
            space!(r)
            if r.s[r.i] == UInt8(',')
                r.i += 1
                continue
            end
            expect!(r, '}')
            return m
        end
    elseif c == '['
        r.i += 1
        a = Any[]
        space!(r)
        if r.s[r.i] == UInt8(']')
            r.i += 1
            return a
        end
        while true
            push!(a, value!(r))
            space!(r)
            if r.s[r.i] == UInt8(',')
                r.i += 1
                continue
            end
            expect!(r, ']')
            return a
        end
    elseif c == '"'
        return string!(r)
    elseif c == 't'
        r.i += 4
        return true
    elseif c == 'f'
        r.i += 5
        return false
    elseif c == 'n'
        r.i += 4
        return nothing
    end
    start = r.i
    while r.i <= length(r.s) && Char(r.s[r.i]) in "+-0123456789.eE"
        r.i += 1
    end
    return parse(Float64, String(r.s[start:r.i-1]))
end

function string!(r::Reader)
    expect!(r, '"')
    out = UInt16[]
    while true
        c = r.s[r.i]
        if c == UInt8('"')
            r.i += 1
            return out
        end
        if c != UInt8('\\')
            start = r.i
            while r.i <= length(r.s) && r.s[r.i] != UInt8('"') && r.s[r.i] != UInt8('\\')
                r.i += 1
            end
            append!(out, transcode(UInt16, r.s[start:r.i-1]))
            continue
        end
        e = Char(r.s[r.i+1])
        r.i += 2
        if e == 'n'
            push!(out, 0x0A)
        elseif e == 't'
            push!(out, 0x09)
        elseif e == 'r'
            push!(out, 0x0D)
        elseif e == 'b'
            push!(out, 0x08)
        elseif e == 'f'
            push!(out, 0x0C)
        elseif e == 'u'
            push!(out, parse(UInt16, String(r.s[r.i:r.i+3]); base=16))
            r.i += 4
        else
            push!(out, UInt16(e))
        end
    end
end

"""
Writes the engine's compliance as the benchmark page reads it: the counts, this runner and the calls it makes in each
encoding it asked in, and what it leaves out.
"""
function write_compliance(path::String, t::Counts)
    calls = String[]
    AS_UTF16[] && push!(calls, "\"utf16\":[\"occursin\",\"CorvusRegexECMA262.exec_slots\",\"CorvusRegexECMA262.find_all\"," *
                               "\"CorvusRegexECMA262.replace_units\",\"CorvusRegexECMA262.split_units\"]")
    AS_UTF8[] && push!(calls, "\"utf8\":[\"occursin\",\"CorvusRegexECMA262.exec_slots\",\"CorvusRegexECMA262.find_all\"," *
                              "\"CorvusRegexECMA262.replace_units\"]")
    json = "{\"right\":$(t.right),\"wrong\":$(t.wrong),\"refused\":$(t.refused),\"acceptedInvalid\":$(t.accepted)," *
           "\"limited\":$(t.limited + t.errors),\"judge\":{\"runner\":" *
           "\"https://github.com/corvus-dotnet/CorvusRegexECMA262.jl/blob/main/tools/dataset/run.jl\"," *
           "\"calls\":{$(join(calls, ","))}},\"excludes\":[]}\n"
    write(path, json)
end

function main(args::Vector{String})
    compliance = ""
    at = findfirst(==("--compliance"), args)
    if at !== nothing
        compliance = args[at+1]
        deleteat!(args, at:at+1)
    end
    at = findfirst(==("--edition"), args)
    if at !== nothing
        e = args[at+1]
        e in ("current", "es2020") || error("the edition is current or es2020, not $e")
        EDITION[] = Symbol(e)
        deleteat!(args, at:at+1)
    end
    at = findfirst(==("--unicode"), args)
    if at !== nothing
        v = replace(args[at+1], ".0" => "")
        v in ("13", "17", "18", "latest") || error("the Unicode version is 13, 17, 18 or latest, not $v")
        UNICODE_VERSION[] = v == "latest" ? :latest : parse(Int, v)
        deleteat!(args, at:at+1)
    end
    if length(args) < 2
        println(stderr, "usage: run.jl <data directory> <wrong-cases output file> [file filter] [utf16|utf8|both] [--compliance <file>] [--edition current|es2020] [--unicode 13|17|18|latest]")
        exit(2)
    end
    directory, wrong_path = args[1], args[2]
    filter = length(args) > 2 ? args[3] : "*.jsonl"
    encodings = length(args) > 3 ? args[4] : "both"
    AS_UTF16[] = encodings in ("both", "utf16")
    AS_UTF8[] = encodings in ("both", "utf8")
    glob = Regex("^" * replace(filter, "." => "\\.", "*" => ".*") * "\$")
    files = sort([f for f in readdir(directory) if occursin(glob, f) && endswith(f, ".jsonl") && isfile(joinpath(directory, f))])
    # The exec calls of test262: with the default filter, or one that names them.
    if (filter == "*.jsonl" || startswith(filter, "exec")) && isfile(joinpath(directory, EXEC))
        push!(files, EXEC)
    end
    total = Counts()
    wrong_cases = String[]
    records, skipped = Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)
    clock = time()
    for name in files
        lines = filter_lines(readlines(joinpath(directory, name)))
        nt = Threads.nthreads()
        counts = [Counts() for _ in 1:nt]
        wrongs = [String[] for _ in 1:nt]
        next = Threads.Atomic{Int}(1)
        Threads.@sync for w in 1:nt
            Threads.@spawn begin
                while true
                    k = Threads.atomic_add!(next, 1)
                    k > length(lines) && break
                    r = parse_json(lines[k])
                    if get_(r, "v8_deviation") == true
                        Threads.atomic_add!(skipped, 1)
                        continue
                    end
                    Threads.atomic_add!(records, 1)
                    judge_record(name, r, counts[w], wrongs[w])
                end
            end
        end
        c = Counts()
        foreach(o -> add!(c, o), counts)
        foreach(w -> append!(wrong_cases, w), wrongs)
        println(rpad(name, 24), " right ", lpad(c.right, 10), "  wrong ", lpad(c.wrong, 6), "  refused-valid ", lpad(c.refused, 4),
            "  accepted-invalid ", lpad(c.accepted, 4), "  limit ", lpad(c.limited, 4), "  ", lpad(string(round(time() - clock; digits=1)), 6), "s")
        add!(total, c)
    end
    sort!(wrong_cases)
    write(wrong_path, isempty(wrong_cases) ? "" : join(wrong_cases, "\n") * "\n")
    compliance == "" || write_compliance(compliance, total)
    println()
    println("records $(records[]) (skipped $(skipped[]) deviations)  right $(total.right)  wrong $(total.wrong)  " *
            "refused-valid $(total.refused)  accepted-invalid $(total.accepted)  limit $(total.limited)  errors $(total.errors)  " *
            "in $(round(time() - clock; digits=1))s")
    println("grammar-only reader: right $(READER_RIGHT[])  wrong $(READER_WRONG[])")
    total.wrong + total.refused + total.accepted + total.errors + total.limited + READER_WRONG[] == 0 || exit(1)
end

filter_lines(lines) = [l for l in lines if !isempty(strip(l))]

main(copy(ARGS))
