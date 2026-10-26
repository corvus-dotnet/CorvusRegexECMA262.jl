# Finding where a match can start (section 4.3 of the design of the .NET reference engine), worked out once from the
# syntax tree when a pattern is compiled (search.rs).
#
# A search on a long text spends most of its time looking for where to start, so before the matcher runs the program
# applies what it learned at compile time. What is searched for (an "anchor") is a literal, each of whose characters may
# have several forms (a letter's cases under the i flag, or the members of a small class), that every match holds at a
# known number of characters from its start: one number, or a bounded range. A pattern that is an alternation, or that
# holds one after a bounded prefix (.{0,2}(Tom|Sawyer)), has an anchor in each alternative, and all of them are searched
# for at once (literals.jl). Each occurrence opens the window of starts from which some alternative could reach it; the
# starts are tried in order and never twice (the alternation windows). Where every alternative starts with its literal,
# the matcher runs at the occurrence alone.
#
# A pattern that starts with loops with no upper bound, then a literal ([a-zA-Z]+ing, \w+\s+Holmes), has the literal
# searched for and the runs of the loops' sets before it walked back to the earliest start, which is the only one tried
# for that occurrence: a later start in the same run can only reach a subset of the places the loops can end at.

# How the search finds where a match can start, beyond the first set. PLAN_SCAN tries every position the first set
# allows. PLAN_WINDOWS: every match holds one of the literals lo to hi characters after its start; rest is the anchored
# automaton of the anchors and the terms after each, run at an occurrence first where a window has more than one start:
# where nothing from the occurrence on can match, its window is not tried. PLAN_AFTER_LOOPS: every match is runs of the
# loops' sets, then the literal; rest is the anchored automaton of the literal and the terms after it, run at each
# occurrence first.
@enum SearchPlan::UInt8 PLAN_SCAN PLAN_WINDOWS PLAN_AFTER_LOOPS

# The shape of a pattern whose matches the search finds without running the matcher (the .NET reference engine's
# simple shapes). Only for a pattern with no group. SHAPE_LITERALS is literals and nothing else, an alternation of them
# or one, with every form of each written out: the search's own match, which is the first literal in the pattern's
# order of those that start leftmost. SHAPE_FORMS is an alternation of literals each of whose characters has several
# forms: at each occurrence the search finds, the alternatives are compared in order. SHAPE_SET is one class and nothing
# else: every member is a match. SHAPE_LOOP is one greedy loop of a class with no upper bound and a least count of zero
# or one: a match is the run of members from where it starts.
@enum SearchShape::UInt8 SHAPE_NONE SHAPE_LITERALS SHAPE_FORMS SHAPE_SET SHAPE_LOOP

# How the end of a run of a loop's members is found (RunEnd of search.rs). RUN_EACH finds it a member at a time.
# RUN_ALL: the set holds every character, and the run is the rest of the text. RUN_STOPS: the set holds every character
# but up to three ASCII ones, found by the searches for bytes. RUN_LINE: the set holds every character but the four line
# terminators (the dot): LF and CR are found by the search for bytes, with the lead byte of U+2028 and U+2029, which is
# looked at further where it is found.
@enum RunEndKind::UInt8 RUN_EACH RUN_ALL RUN_STOPS RUN_LINE

# The most literals the forms of one anchor are expanded to.
const MAX_FORMS = 64
# The most literals of all the anchors of a pattern.
const MAX_LITERALS = 512
# The most characters a window of starts may span.
const MAX_WINDOW = 64

# The checks a RestCheck makes before it decides whether it pays.
const REST_TRIALS = 64

"""
The anchored automaton of what follows an occurrence (an anchor and the terms after it), run at the occurrence before
any start is walked back to. A check that seldom rules an occurrence out costs more than it saves (an e-mail address's
@ is nearly always followed by a domain), so the check keeps count over its first trials and is dropped for good when
fewer than one in eight of them ruled the occurrence out. The counts change only how fast a search is, never what it
finds.
"""
struct RestCheck
    dfa::AnchoredDfa
    checks::Threads.Atomic{Int}
    rejects::Threads.Atomic{Int}
end

RestCheck(dfa::AnchoredDfa) = RestCheck(dfa, Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))

"Whether the check is still made."
@inline pays(r::RestCheck) = r.checks[] < REST_TRIALS || r.rejects[] * 8 >= REST_TRIALS

"""
Counts a check while it is still on trial: each of the first REST_TRIALS checks once, whichever tasks make them, and
none after (the load keeps the counter from being written on every check once the trial is over).
"""
@inline function count!(r::RestCheck, out::Bool)
    if r.checks[] < REST_TRIALS && Threads.atomic_add!(r.checks, 1) < REST_TRIALS && out
        Threads.atomic_add!(r.rejects, 1)
    end
end

"""
A search for any of a few bytes: the searches for one to three bytes, and a table for up to sixty-four, which is the set
the crate finds with the fingerprint search of one-byte literals.
"""
struct FirstBytes
    count::Int
    a::UInt8
    b::UInt8
    c::UInt8
    table::BitVector
end

function first_bytes(set::CharSet, units::Bool)
    table = falses(256)
    r = set.ranges
    spans = ((0, 0x7F, 0, 0x00), (0x80, 0x7FF, 6, 0xC0), (0x800, 0xFFFF, 12, 0xE0), (0x10000, 0x10FFFF, 18, 0xF0))
    for k in 1:2:length(r)
        lo, hi = r[k], r[k+1]
        # A surrogate without the u flag is half of a character of four bytes, and U+FFFD is also what a byte that is
        # not UTF-8 reads as: neither starts at a byte the set can name.
        (units && lo <= 0xDFFF && hi >= 0xD800 || lo <= 0xFFFD && hi >= 0xFFFD) && return nothing
        for (slo, shi, shift, lead) in spans
            x, y = max(lo, slo), min(hi, shi)
            if x <= y
                for b in (lead | x >> shift):(lead | y >> shift)
                    table[b+1] = true
                end
            end
        end
    end
    list = [UInt8(b - 1) for b in 1:256 if table[b]]
    (isempty(list) || length(list) > MAX_FORMS) && return nothing
    n = length(list)
    return FirstBytes(n, list[1], list[min(2, n)], list[min(3, n)], table)
end

"The first position at or after `from` whose byte is one of the bytes, or -1."
function find(f::FirstBytes, h::Bytes, from::Int)
    n = length(h)
    f.count == 1 && return index_byte(h, from, n, f.a)
    f.count == 2 && return index_byte2(h, from, n, f.a, f.b)
    f.count == 3 && return index_byte4(h, from, n, f.a, f.b, f.c, f.c)
    table = f.table
    @inbounds for at in from:n-1
        table[h[at+1]+1] && return at
    end
    return -1
end

"""
The test for the code units a match can start with over UTF-16: the first set's units as up to eight ranges (a member
beyond the BMP as its lead surrogate), where more are merged across the narrowest gaps, the ASCII and Latin ones last
since those units are common in text. A candidate is then tested against the first set itself.
"""
function first_units(set::CharSet)
    lead(cp) = 0xD800 + (cp - 0x10000) >> 10
    units = Tuple{Int,Int}[]
    r = set.ranges
    for k in 1:2:length(r)
        lo, hi = r[k], r[k+1]
        lo <= 0xFFFF && push!(units, (lo, min(hi, 0xFFFF)))
        hi > 0xFFFF && push!(units, (lead(max(lo, 0x10000)), lead(hi)))
    end
    sort!(units)
    merged = Tuple{Int,Int}[]
    for u in units
        if !isempty(merged) && u[1] <= merged[end][2] + 1
            merged[end] = (merged[end][1], max(merged[end][2], u[2]))
        else
            push!(merged, u)
        end
    end
    while length(merged) > 8
        # The gap whose units are least likely in text: its width, a thousand times over below U+0300.
        best, best_cost = 1, typemax(Int)
        for k in 1:length(merged)-1
            a, b = merged[k][2] + 1, merged[k+1][1]
            cost = (b - a) * (a < 0x300 ? 1000 : 1)
            if cost < best_cost
                best_cost, best = cost, k
            end
        end
        merged[best] = (merged[best][1], merged[best+1][2])
        deleteat!(merged, best + 1)
    end
    isempty(merged) && return nothing
    return UnitSet(Int[x for m in merged for x in m])
end

"What a pattern's search knows of it."
mutable struct Search
    plan::SearchPlan
    shape::SearchShape
    # The literals of the windows and of the search after loops, and the distances of the windows.
    literals::Union{Nothing,Literals}
    lo::Int
    hi::Int
    # The reverse automaton of the windows' prefixes (see build_reverse_dfa).
    reverse::Union{Nothing,ReverseDfa}
    # The check of what follows an occurrence (see RestCheck).
    rest::Union{Nothing,RestCheck}
    # The loops of the search after loops, and their least counts.
    sets::Vector{CharSet}
    mins::Vector{Int}
    # The alternatives of SHAPE_FORMS: for each, the forms of each of its characters.
    forms::Vector{Vector{Vector{Int}}}
    # The class of SHAPE_SET and SHAPE_LOOP, the loop's least count, and how its run ends.
    shape_set::Union{Nothing,CharSet}
    shape_min::Int
    run_end::RunEndKind
    # The bytes of RUN_STOPS (the last repeated to three), and the units that end a run over UTF-16, for RUN_STOPS and
    # RUN_LINE.
    stops::NTuple{3,UInt8}
    n_stops::Int
    stops16::Union{Nothing,UnitSet}
    # The set of a loop every match starts with, when a start that fails may move to the end of the run of its set:
    # every start in the rest of the run can only reach a subset of the places the loop can end at.
    skip_run::Union{Nothing,CharSet}
    # The pattern starts with \b and every character a match can start with is an ASCII word character, so a start
    # inside a word fails and the search passes over the rest of the word.
    leading_word_boundary::Bool
    # The bytes a match can start with over UTF-8, searched for together when they are few: the first set's ASCII
    # members and the lead bytes of its other members.
    first_bytes::Union{Nothing,FirstBytes}
    # The code units a match can start with over UTF-16.
    first_units::Union{Nothing,UnitSet}
end

Search() = Search(PLAN_SCAN, SHAPE_NONE, nothing, 0, 0, nothing, nothing, CharSet[], Int[], Vector{Vector{Int}}[],
    nothing, 0, RUN_EACH, (0x00, 0x00, 0x00), 0, nothing, nothing, false, nothing, nothing)

# Makes every pattern compiled while it is set try every position its first set allows, which the tests compare the
# searches with.
const NO_SEARCH = Threads.Atomic{Bool}(false)

"One literal every match of an alternative holds, lo to hi characters after its start."
struct Anchor
    # The forms of each of its characters.
    chars::Vector{Vector{Int}}
    lo::Int
    hi::Int
    # The terms a match goes through before the anchor, and the terms from the anchor on, to the end of the pattern.
    prefix::Vector{Node}
    rest::Vector{Node}
end

"The forms of a character the search can look for: a literal code point, or the members of a small class; or nothing."
function forms(n::Node)
    n.kind == N_CHAR && return literal_rune(n.r) ? [n.r] : nothing
    n.kind == N_SET || return nothing
    r = n.set.ranges
    out = Int[]
    for k in 1:2:length(r)
        lo, hi = r[k], r[k+1]
        (hi - lo >= 4 || length(out) + (hi - lo + 1) > 4) && return nothing
        for c in lo:hi
            literal_rune(c) || return nothing
            push!(out, c)
        end
    end
    # An empty class has no form to look for.
    return isempty(out) ? nothing : out
end

"The terms of a node in order: a sequence and a group whose body is a sequence are spliced in."
function terms(n::Node)
    out = Node[]
    function add(n::Node)
        if n.kind == N_CAT
            foreach(add, n.subs)
        elseif n.kind == N_GROUP
            n.subs[1].kind != N_ALT ? add(n.subs[1]) : push!(out, n)
        elseif n.kind != N_EMPTY
            push!(out, n)
        end
    end
    add(n)
    return out
end

# A bound past every window, so that sums of widths saturate there.
const FAR = 1 << 40

add_far(a::Int, b::Int) = min(a + b, FAR)
mul_far(a::Int, b::Int) = (a == 0 || b == 0) ? 0 : min(a, FAR) * min(b, FAR) >= FAR ? FAR : a * b

"""
The least and the greatest number of characters a node consumes (the greatest -1 for no bound), and false when it is
not known (a backreference).
"""
function width(n::Node)
    k = n.kind
    (k == N_CHAR || k == N_SET) && return 1, 1, true
    if k == N_CAT
        lo, hi = 0, 0
        for sub in n.subs
            a, b, ok = width(sub)
            ok || return 0, 0, false
            lo = add_far(lo, a)
            hi = (hi < 0 || b < 0) ? -1 : add_far(hi, b)
        end
        return lo, hi, true
    elseif k == N_ALT
        first = true
        lo, hi = 0, 0
        for sub in n.subs
            a, b, ok = width(sub)
            ok || return 0, 0, false
            if first
                lo, hi, first = a, b, false
            else
                lo = min(lo, a)
                hi = (hi < 0 || b < 0) ? -1 : max(hi, b)
            end
        end
        return lo, hi, true
    elseif k == N_GROUP
        return width(n.subs[1])
    elseif k == N_REPEAT
        a, b, ok = width(n.subs[1])
        ok || return 0, 0, false
        lo = mul_far(a, n.min)
        hi = if n.max == UNBOUNDED && b == 0
            0
        elseif n.max == UNBOUNDED || b < 0
            -1
        else
            mul_far(b, n.max)
        end
        return lo, hi, true
    elseif k == N_BACKREF
        return 0, 0, false
    end
    return 0, 0, true
end

"""
The anchors of a node whose match starts lo to hi characters after the start of the whole match: the first run of
literal characters of each of its alternatives, or nothing when some alternative has none at a bounded distance.
"""
anchors(n::Node, lo::Int, hi::Int) = anchors_after(n, lo, hi, Node[], Node[])

"The anchors of n, which the terms `before` precede and the terms `after` follow."
function anchors_after(n::Node, lo::Int, hi::Int, before::Vector{Node}, after::Vector{Node})
    ts = terms(n)
    prefix = copy(before)
    k = 1
    while k <= length(ts)
        t = ts[k]
        if forms(t) !== nothing
            rest = vcat(ts[k:end], after)
            chars = Vector{Int}[]
            while k <= length(ts)
                f = forms(ts[k])
                f === nothing && break
                push!(chars, f)
                k += 1
            end
            return [Anchor(chars, lo, hi, prefix, rest)]
        end
        alt = t.kind == N_ALT ? t : (t.kind == N_GROUP && t.subs[1].kind == N_ALT ? t.subs[1] : nothing)
        if alt !== nothing
            following = vcat(ts[k+1:end], after)
            all = Anchor[]
            for sub in alt.subs
                found = anchors_after(sub, lo, hi, prefix, following)
                found === nothing && return nothing
                append!(all, found)
            end
            return all
        end
        a, b, ok = width(t)
        (!ok || b < 0) && return nothing
        lo, hi = add_far(lo, a), add_far(hi, b)
        hi > MAX_WINDOW && return nothing
        push!(prefix, t)
        k += 1
    end
    return nothing
end

"The literals of an anchor: the forms of its first `count` characters written out."
function expand(a::Anchor, count::Int)
    out = [Int[]]
    for f in a.chars[1:count]
        out = [vcat(prefix, r) for prefix in out for r in f]
    end
    return out
end

"""
The most bytes of each of an anchor's literals written out over UTF-8: where the anchor was cut short, every literal is
cut to the bytes of its shortest, so that the forms of a character longer than the others (the long s, two bytes beside
the one of s) make no more literals than the others. The regex crate's rule.
"""
function utf8_cuts(cut_short::Bool, lits::Vector{Vector{Int}})
    cut = typemax(Int)
    if cut_short
        for l in lits
            cut = min(cut, sum(rune_len, l; init=0))
        end
    end
    return fill(cut, length(lits))
end

"The number of literals the anchors make with the first k characters of each written out."
function total_literals(as::Vector{Anchor}, k::Int)
    t = 0
    for a in as
        p = 1
        for c in 1:min(length(a.chars), k)
            p = mul_far(p, length(a.chars[c]))
        end
        t = add_far(t, p)
    end
    return t
end

"""
How many of each anchor's characters to write out, and whether the anchors were cut short. Exact anchors are written
out in full. Where a character has several forms (a letter under the i flag), every anchor is cut to one length by the
rule of the regex crate's literal optimisation (Seq::optimize_by_preference): the full literals if they are ten or
fewer, else five characters if that makes ten or fewer, else four if that makes sixty-four or fewer, else three if
sixty-four or fewer, else two if ten or fewer, else one.
"""
function literal_counts(as::Vector{Anchor})
    exact = all(a -> all(f -> length(f) == 1, a.chars), as)
    all_ = typemax(Int)
    k = if exact || total_literals(as, all_) <= 10
        all_
    elseif total_literals(as, 5) <= 10
        5
    elseif total_literals(as, 4) <= MAX_FORMS
        4
    elseif total_literals(as, 3) <= MAX_FORMS
        3
    elseif total_literals(as, 2) <= 10
        2
    else
        1
    end
    return [min(length(a.chars), k) for a in as], !exact && k != all_
end

"Whether a set holds ASCII word characters alone."
function ascii_word_set(f::Union{Nothing,CharSet})
    (f === nothing || isempty(f.ranges) || f.ranges[end] >= 0x80) && return false
    for c in 0:0x7f
        has_ascii(f, c) && !is_word_byte(c) && return false
    end
    return true
end

"""
The top-level alternatives of a tree: the alternatives of an alternation (in a group or not), or the tree.
"""
function alternatives(root::Node)
    root.kind == N_ALT && return root.subs
    root.kind == N_GROUP && root.group == 0 && root.subs[1].kind == N_ALT && return root.subs[1].subs
    return [root]
end

"Whether a node holds a capturing group."
holds_group(n::Node) = n.kind == N_GROUP && n.group > 0 || any(holds_group, n.subs)

"""
Sets the literal shapes of a tree whose anchors are found: literals and nothing else, exact or with forms.
"""
function shape_of_literals!(s::Search, root::Node, found::Vector{Anchor}, counts::Vector{Int}, cut_short::Bool)
    holds_group(root) && return
    alts = alternatives(root)
    all = Vector{Vector{Vector{Int}}}(undef, length(alts))
    for (a, alt) in enumerate(alts)
        ts = terms(alt)
        isempty(ts) && return
        all[a] = Vector{Vector{Int}}(undef, length(ts))
        for (k, t) in enumerate(ts)
            f = forms(t)
            f === nothing && return
            all[a][k] = f
        end
    end
    # Literals written out in full, every form of each, are the search's own literals, in the pattern's order (an
    # alternative's forms together), so the search's leftmost-first match is the pattern's.
    literal = !cut_short && length(found) == length(all)
    a = 1
    while a <= length(all) && literal
        literal = found[a].lo == 0 && found[a].hi == 0 && counts[a] == length(all[a])
        a += 1
    end
    if literal
        s.shape = SHAPE_LITERALS
    else
        s.shape, s.forms = SHAPE_FORMS, all
    end
end

"The set of a loop of one character or class with no upper bound, or nothing."
function open_loop(t::Node)
    (t.kind != N_REPEAT || t.max != UNBOUNDED) && return nothing
    body = t.subs[1]
    body.kind == N_SET && return body.set
    body.kind == N_CHAR && return CharSet(Int[body.r, body.r])
    return nothing
end

"Sets the class and loop shapes of a tree that is one term."
function shape_of_one!(s::Search, root::Node)
    holds_group(root) && return
    ts = terms(root)
    length(ts) == 1 || return
    t = ts[1]
    if t.kind == N_SET && !isempty(t.set)
        s.shape, s.shape_set = SHAPE_SET, t.set
    elseif t.kind == N_REPEAT && !t.lazy && t.min <= 1
        set = open_loop(t)
        if set !== nothing && !isempty(set)
            s.shape, s.shape_set, s.shape_min = SHAPE_LOOP, set, t.min
            set_run_end!(s, set)
        end
    end
end

"Sets how the end of a run of the set's members is found."
function set_run_end!(s::Search, set::CharSet)
    c = complement(set).ranges
    if isempty(c)
        s.run_end = RUN_ALL
        return
    end
    if c == [0x0A, 0x0A, 0x0D, 0x0D, 0x2028, 0x2029]
        s.run_end, s.stops16 = RUN_LINE, UnitSet(copy(c))
        return
    end
    stops = UInt8[]
    for k in 1:2:length(c)
        lo, hi = c[k], c[k+1]
        if hi >= 0x80 || hi - lo >= 3 || length(stops) + (hi - lo + 1) > 3
            s.run_end = RUN_EACH
            return
        end
        append!(stops, UInt8(lo):UInt8(hi))
    end
    n = length(stops)
    while length(stops) < 3
        push!(stops, stops[n])
    end
    s.run_end, s.n_stops, s.stops, s.stops16 = RUN_STOPS, n, (stops[1], stops[2], stops[3]), UnitSet(copy(c))
end

"""
The search of a tree, after simplify. `backrefs` says the pattern has a backreference, which rules out what depends on
a start reaching a subset of another's places; `first` is the first set of the program.
"""
function plan_search(root::Node, backrefs::Bool, first::Union{Nothing,CharSet}, units::Bool)
    s = Search()
    NO_SEARCH[] && return s
    if first !== nothing
        s.first_bytes = first_bytes(first, units)
        s.first_units = first_units(first)
    end
    ts = terms(root)
    # A leading \b before characters that are all ASCII word characters.
    boundary = !isempty(ts) && ts[1].kind == N_WORD_BOUNDARY && !ts[1].fold
    boundary && ascii_word_set(first) && (s.leading_word_boundary = true)
    found = anchors(root, 0, 0)
    if found !== nothing
        lits = Vector{Int}[]
        cuts = Int[]
        lo, hi = typemax(Int), 0
        counts, cut_short = literal_counts(found)
        for (i, a) in enumerate(found)
            lo, hi = min(lo, a.lo), max(hi, a.hi)
            expanded = expand(a, counts[i])
            c = utf8_cuts(cut_short, expanded)
            for (e, l) in enumerate(expanded)
                if !(l in lits)
                    push!(lits, l)
                    push!(cuts, c[e])
                end
            end
        end
        if 0 < length(lits) <= MAX_LITERALS && all(!isempty, lits)
            shape_of_literals!(s, root, found, counts, cut_short)
            s.literals = Literals(lits, cuts)
            # Where a window has more than one start, the terms before the anchors are matched backwards from each
            # occurrence, so that only the starts they allow are tried (the reverse search of the regex crate).
            if hi > 0
                prefixes = [a.prefix for a in found]
                longer = any(a -> length(a.rest) > length(a.chars), found)
                s.reverse = build_reverse_dfa(prefixes)
                # Where every anchor is the end of its alternative, the occurrence is all the rest there is to check.
                if longer
                    alts = [with_subs(N_CAT, a.rest...) for a in found]
                    dfa = build_adfa(with_subs(N_ALT, alts...))
                    dfa === nothing || (s.rest = RestCheck(dfa))
                end
            end
            s.plan, s.lo, s.hi = PLAN_WINDOWS, lo, hi
            return s
        end
    end
    shape_of_one!(s, root)
    backrefs && return s
    # Loops with no upper bound, then a literal.
    k = boundary ? 2 : 1
    sets = CharSet[]
    mins = Int[]
    while k <= length(ts)
        set = open_loop(ts[k])
        set === nothing && break
        push!(sets, set)
        push!(mins, ts[k].min)
        k += 1
    end
    isempty(sets) && return s
    # \b is allowed when every loop's set is of word characters (a later start of the runs can be in any loop's run,
    # where \b holds after a word character before a member that is not one: \b\d*\s*a over " a"), and the sets must
    # share no character, any two of them.
    words = all(ascii_word_set, sets)
    disjoint = all(isempty(intersect(sets[i], sets[j])) for i in eachindex(sets) for j in i+1:length(sets))
    small = all(<=(1), mins)
    chars = Vector{Int}[]
    literal_at = k
    while k <= length(ts)
        f = forms(ts[k])
        f === nothing && break
        push!(chars, f)
        k += 1
    end
    if (!boundary || words) && disjoint && small && !isempty(chars)
        a = Anchor(chars, 0, 0, Node[], Node[])
        count, cut_short = literal_counts([a])
        lits = expand(a, count[1])
        rest = ts[literal_at:end]
        s.plan, s.literals, s.sets, s.mins = PLAN_AFTER_LOOPS, Literals(lits, utf8_cuts(cut_short, lits)), sets, mins
        if length(rest) > length(a.chars)
            dfa = build_adfa(with_subs(N_CAT, rest...))
            dfa === nothing || (s.rest = RestCheck(dfa))
        end
    end
    # A failed start may skip the rest of its leading loop's run (the loop is the first term).
    boundary || (s.skip_run = sets[1])
    return s
end
