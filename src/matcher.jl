# The backtracking matcher (vm.rs), written once over a vector of code units: Julia compiles it for each encoding, UTF-8
# bytes (`Bytes`) and UTF-16 code units (`Units`), so each is the matcher of one encoding with no branch on the encoding
# inside it. Positions are 0-based offsets, as in the crate.

@inline is_utf8(::Bytes) = true
@inline is_utf8(::Units) = false

@inline lit_of(i::Inst, ::Bytes) = i.lit8
@inline lit_of(i::Inst, ::Units) = i.lit16
@inline need_of(i::Inst, ::Bytes) = i.need8
@inline need_of(i::Inst, ::Units) = i.need16
@inline iter_of(i::Inst, ::Bytes) = i.iter8
@inline iter_of(i::Inst, ::Units) = i.iter16

"Whether the units of `lit` are at `pos` of the text (which has them all)."
@inline function equal_at(input::AbstractVector, pos::Int, lit::AbstractVector)
    @inbounds for k in 1:length(lit)
        input[pos+k] == lit[k] || return false
    end
    return true
end

"Whether the n units at `a` and at `b` of the text are the same."
@inline function equal_runs(input::AbstractVector, a::Int, b::Int, n::Int)
    @inbounds for k in 1:n
        input[a+k] == input[b+k] || return false
    end
    return true
end

"""
Finds the first match at or after `start` (at `start` alone with `sticky`), and returns where it starts and ends and
whether it was found. When it finds one and `caps` is given, `caps` receives, from index `offset`, the start and end of
each group the program records, or -1 for a group that did not take part. With a limit (in nanoseconds) the match is
abandoned when it has run for longer than that, or when its stack has reached MAX_STACK, and the error says which.
"""
function exec(p::Program, input::Text16or8, start::Int, sticky::Bool, limit::Int, caps::Union{Nothing,Vector{Int}},
    offset::Int=1, held::Union{Nothing,State}=nothing)
    # A pattern of a simple shape with no group is answered by the search alone, with nothing of the matcher's.
    if p.groups == 0 && !sticky && !p.anchored && p.search.shape != SHAPE_NONE
        return shape_search(p, input, start)
    end
    # A global search holds one state for all its matches (see with_state); a single match takes one from the pool.
    st = held === nothing ? take_state() : held
    reset!(st, p, length(input), limit)
    from, found = search(p, st, input, start, sticky)
    to = st.end_
    stop = st.stop
    found && caps !== nothing && copyto!(caps, offset, st.caps, 1, length(st.caps))
    if held === nothing
        release!(st)
        give_state(st)
    end
    throw_stop(stop, limit)
    return from, to, found
end

"""
f(st) with a state taken from the pool and given back after, for a global search: taking a state and giving it back is
work for each match that one search of many matches pays once.
"""
function with_state(f, p::Program)
    # A search of a simple shape uses no state (see exec).
    p.groups == 0 && !p.anchored && p.search.shape != SHAPE_NONE && return f(nothing)
    st = take_state()
    try
        return f(st)
    finally
        release!(st)
        give_state(st)
    end
end

function search(p::Program, st::State, input::Text16or8, start::Int, sticky::Bool)
    len = length(input)
    n = need(p, input)
    (start > len || len - start < n) && return 0, false
    if sticky || p.anchored
        p.anchored && start > 0 && return 0, false
        return start, run!(p, st, input, start)
    end
    plan = p.search.plan
    plan == PLAN_WINDOWS && return search_windows(p, st, input, start, n)
    plan == PLAN_AFTER_LOOPS && return search_after_loops(p, st, input, start, n)
    return scan(p, st, input, start, n)
end

"The width of the character at a position before the end."
@inline function width_at(p::Program, input::Text16or8, at::Int)
    unit(input, at) < 0x80 && return 1
    return read_at(input, at, p.units)[2]
end

"The first match at or after `start` of a pattern of a simple shape."
function shape_search(p::Program, input::Text16or8, start::Int)
    s = p.search
    (start > length(input) || length(input) - start < need(p, input)) && return 0, 0, false
    if s.shape == SHAPE_LITERALS
        from, to = find_literals(s.literals::Literals, input, start)
        return from, to, from >= 0
    elseif s.shape == SHAPE_FORMS
        return forms_match(p, input, start)
    elseif s.shape == SHAPE_SET
        at, w = next_member(p, s.shape_set::CharSet, input, start)
        return at, at + w, at >= 0
    end
    return loop_match(p, input, start)
end

"The first match at or after `start` of the shape of an alternation of literals with forms."
function forms_match(p::Program, input::Text16or8, start::Int)
    s = p.search
    lits = s.literals::Literals
    units = p.units
    n = length(input)
    next = start
    while true
        q, _ = find_literals(lits, input, next)
        q < 0 && return 0, 0, false
        # The automaton compares several alternatives at once where the text is ASCII; one is compared faster as it is.
        dfa = p.anchored_dfa
        if dfa !== nothing && length(s.forms) > 1
            end_ = find(dfa, input, q)
            end_ >= 0 && return q, end_, true
            if end_ == ADFA_NONE
                next = q + width_at(p, input, q)
                continue
            end
        end
        for alt in s.forms
            at = q
            ok = true
            for f in alt
                if at >= n
                    ok = false
                    break
                end
                c = unit(input, at)
                r, w = Int(c), 1
                c >= 0x80 && ((r, w) = read_at(input, at, units))
                if !(r in f)
                    ok = false
                    break
                end
                at += w
            end
            ok && return q, at, true
        end
        next = q + width_at(p, input, q)
    end
end

"The first match at or after `start` of the shape of one greedy loop of a class."
function loop_match(p::Program, input::Text16or8, start::Int)
    s = p.search
    set = s.shape_set::CharSet
    from = start
    if s.shape_min != 0
        at, _ = next_member(p, set, input, start)
        at < 0 && return 0, 0, false
        from = at
    end
    to = run_end(s, input, from)
    to < 0 && (to = end_of_run(p, set, input, from))
    return from, to, true
end

"The first member of the set at or after `at` and its width, or -1."
function next_member(p::Program, set::CharSet, input::Text16or8, at::Int)
    while true
        at = first_find(p, input, at)
        (at < 0 || at >= length(input)) && return -1, 0
        c = unit(input, at)
        if c < 0x80
            has_ascii(set, c) && return at, 1
            at += 1
        else
            r, w = read_at(input, at, p.units)
            r in set && return at, w
            at += w
        end
    end
end

"Whether a start passes the first set."
@inline function first_allows(p::Program, input::Text16or8, at::Int)
    first = p.first
    first === nothing && return true
    at >= length(input) && return false
    c = unit(input, at)
    c < 0x80 && return has_ascii(first, c)
    return read_at(input, at, p.units)[1] in first
end

"Whether the program matches at the start, with the reason for stopping in st.stop."
@inline try_at(p::Program, st::State, input::Text16or8, at::Int) = first_allows(p, input, at) && run!(p, st, input, at)

"Whether nothing from the occurrence at q on can match, by the check's automaton while it pays."
function rules_out(r::Union{Nothing,RestCheck}, input::Text16or8, q::Int)
    (r === nothing || !pays(r)) && return false
    out = matches_at(r.dfa, input, q) == 0
    count!(r, out)
    return out
end

"""
The position n characters before `at`, not before `floor` (the furthest it gets when there are fewer), and the
characters it went back over.
"""
function walk_back(p::Program, input::Text16or8, at::Int, n::Int, floor::Int)
    k = 0
    while k < n && at > floor
        _, w = read_last(input, at, p.units)
        at - w < floor && break
        at -= w
        k += 1
    end
    return at, k
end

"""
The search of a pattern each of whose matches holds one of the literals lo to hi characters after its start: each
occurrence opens the window of starts that could reach it, tried in order and never twice.
"""
function search_windows(p::Program, st::State, input::Text16or8, start::Int, need::Int)
    s = p.search
    if s.reverse !== nothing && s.hi < 127
        at, found, decided = search_reverse(p, st, input, start, need)
        decided && return at, found
    end
    lits = s.literals::Literals
    len = length(input)
    lo, hi = s.lo, s.hi
    next = start
    # Every start before this has been tried.
    untried = start
    while true
        q, _ = find_literals(lits, input, next)
        q < 0 && return 0, false
        next = q + width_at(p, input, q)
        if hi == 0
            # Every alternative starts with its literal: the match starts at the occurrence or not at all.
            len - q < need && return 0, false
            # The occurrence is the literal every match starts with: the automaton goes on after it.
            end_ = after_find(p, input, q)
            if end_ >= 0
                st.end_ = end_
                return q, true
            end
            end_ == ADFA_NONE && continue
            try_at(p, st, input, q) && return q, true
            st.stop != STOP_NONE && return 0, false
            continue
        end
        last, k = walk_back(p, input, q, lo, start)
        (k < lo || last < untried || rules_out(s.rest, input, q)) && continue
        at, _ = walk_back(p, input, q, hi, start)
        while at <= last
            if at >= untried
                len - at < need && return 0, false
                try_at(p, st, input, at) && return at, true
                st.stop != STOP_NONE && return 0, false
            end
            at == len && break
            at += width_at(p, input, at)
        end
        untried = max(untried, at)
    end
end

"""
search_windows with the terms before the anchors read backwards from each occurrence, so that only the starts they allow
are tried; decided is false when a unit beyond ASCII is reached, for the plain search to be made. A start is tried only
once no later occurrence could allow an earlier one (it is before the next occurrence's window), so the starts are
tried in order across occurrences and the first match is the leftmost.
"""
function search_reverse(p::Program, st::State, input::Text16or8, start::Int, need::Int)
    s = p.search
    lits = s.literals::Literals
    reverse = s.reverse::ReverseDfa
    lo, hi = s.lo, s.hi
    len = length(input)
    # The starts waiting to be tried, as two words of bits: bit k is the position base + k.
    pend0, pend1 = UInt64(0), UInt64(0)
    base = start
    # Every start at or before this has been tried, or can no longer be allowed.
    tried = -1
    q, _ = find_literals(lits, input, start)
    q < 0 && return 0, false, true
    while true
        # The starts this occurrence's terms allow join those waiting.
        new_base = max(q - hi, start)
        if new_base > base
            shift = new_base - base
            if shift >= 128
                pend0, pend1 = UInt64(0), UInt64(0)
            elseif shift >= 64
                pend0, pend1 = pend1 >> (shift - 64), UInt64(0)
            else
                pend0, pend1 = pend0 >> shift | pend1 << (64 - shift), pend1 >> shift
            end
            base = new_base
        end
        # An occurrence from which nothing can match allows no start.
        m0, m1 = UInt64(0), UInt64(0)
        if !rules_out(s.rest, input, q)
            m0, m1, ok = starts_before(reverse, input, q, hi, start)
            ok || return 0, false, false
        end
        # No start nearer than lo characters.
        if lo >= 64
            m0, m1 = UInt64(0), m1 & (typemax(UInt64) << (lo - 64))
        elseif lo > 0
            m0 &= typemax(UInt64) << lo
        end
        while m0 | m1 != 0
            if m1 != 0
                d = 127 - leading_zeros(m1)
                m1 &= ~(UInt64(1) << (d - 64))
            else
                d = 63 - leading_zeros(m0)
                m0 &= ~(UInt64(1) << d)
            end
            at = q - d
            if at >= base && at > tried
                b = at - base
                if b < 64
                    pend0 |= UInt64(1) << b
                else
                    pend1 |= UInt64(1) << (b - 64)
                end
            end
        end
        after = q + width_at(p, input, q)
        # The earliest waiting start is tried once no occurrence before it plus the window could allow an earlier one:
        # an occurrence within that reach is taken in first, which looks no further than the reach.
        taken = false
        while pend0 | pend1 != 0
            k = pend0 != 0 ? trailing_zeros(pend0) : 64 + trailing_zeros(pend1)
            at = base + k
            if after <= at + hi
                q2 = find_within(lits, input, after, at + hi)
                if q2 >= 0
                    q, taken = q2, true
                    break
                end
            end
            if k < 64
                pend0 &= ~(UInt64(1) << k)
            else
                pend1 &= ~(UInt64(1) << (k - 64))
            end
            tried = at
            len - at < need && return 0, false, true
            try_at(p, st, input, at) && return at, true, true
            st.stop != STOP_NONE && return 0, false, true
        end
        if !taken
            q, _ = find_literals(lits, input, after)
            q < 0 && return 0, false, true
        end
    end
end

"""
The search of a pattern each of whose matches is runs of the loops' sets, then the literal: the runs before each
occurrence are walked back to the earliest start, which is tried. From that start the loops reach every place a later
start of the run could, so the later starts fail with it; the occurrence itself is not in the run and may start a
match, so it is tried next where every loop may be empty, and is the floor for the walk back from later occurrences
otherwise. A start before an occurrence can reach a later one through it (the literal can be in a loop's set), so an
occurrence ruled out does not move the floor.
"""
function search_after_loops(p::Program, st::State, input::Text16or8, start::Int, need::Int)
    s = p.search
    lits = s.literals::Literals
    sets, mins = s.sets, s.mins
    len = length(input)
    units = p.units
    next = start
    # The floor below which no start is tried again.
    low = start
    all_empty = all(==(0), mins)
    while true
        q, _ = find_literals(lits, input, next)
        q < 0 && return 0, false
        next = q + width_at(p, input, q)
        # A loop that needs a member must have one just before the occurrence: a test of one character, made before the
        # rest is checked.
        if mins[end] == 1
            q <= low && continue
            c = unit(input, q - 1)
            r = c < 0x80 ? Int(c) : read_last(input, q, units)[1]
            r in sets[end] || continue
        end
        rules_out(s.rest, input, q) && continue
        at = q
        skip = false
        for k in length(sets):-1:1
            run_start = at
            while at > low
                c = unit(input, at - 1)
                r, w = Int(c), 1
                c >= 0x80 && ((r, w) = read_last(input, at, units))
                (!(r in sets[k]) || at - w < low) && break
                at -= w
            end
            if mins[k] == 1 && at == run_start
                skip = true
                break
            end
        end
        skip && continue
        len - at < need && return 0, false
        try_at(p, st, input, at) && return at, true
        st.stop != STOP_NONE && return 0, false
        if at < q
            # The occurrence itself (\b[0-9a-f]*ét over "0aét", where the walk back gives 0).
            low = q
            if all_empty
                len - q < need && return 0, false
                try_at(p, st, input, q) && return q, true
                st.stop != STOP_NONE && return 0, false
                low = next
            end
        else
            low = next
        end
        if length(sets) == 1
            # Every occurrence in the rest of the loop's run walks back to the start just tried.
            next = max(next, end_of_run(p, sets[1], input, q))
        end
    end
end

"Tries every start from `start` that the first set allows."
function scan(p::Program, st::State, input::Text16or8, start::Int, need::Int)
    len = length(input)
    units = p.units
    first = p.first
    s = p.search
    fwd = forward(p)
    skip = p.skip
    at = start
    while true
        skip === nothing || (at = skip_ahead(skip, input, at))
        # Every match starts with a member of the first set, which starts with one of the first bytes or units.
        at = first_start(p, input, at)
        at < 0 && return 0, false
        # With the u or v flag the trail half of a pair is not a character a match can start at; the place after it goes
        # back through the skip.
        if !units && s.first_units !== nothing && mid_pair(input, at)
            at += 1
            continue
        end
        len - at < need && return 0, false
        at == len && return at, first === nothing && run!(p, st, input, at)
        c = unit(input, at)
        r, w = Int(c), 1
        c >= 0x80 && ((r, w) = read_at(input, at, units))
        if s.leading_word_boundary && at > 0 && is_word_unit(unit(input, at - 1))
            # Inside a word, where \b cannot hold: the rest of the word is passed over.
            at = max(end_of_run(p, first::CharSet, input, at), at + w)
            continue
        end
        if fwd !== nothing
            # One pass of the forward automaton from here says where a match first ends, or that none starts before a
            # place where no thread is alive; only then are starts tried, from here to there.
            kind, place = scan_dfa(fwd, input, at)
            kind == SCAN_NONE && return 0, false
            if kind == SCAN_IDLE
                at = place
                continue
            end
            found, next, over = try_starts(p, st, input, at, place)
            (found || over) && return next, found
            at = next
            continue
        end
        (first === nothing || r in first) && run!(p, st, input, at) && return at, true
        st.stop != STOP_NONE && return 0, false
        skip_run = s.skip_run
        if skip_run !== nothing && r in skip_run
            # The start failed after its leading loop ate the run from here: every start in the rest of the run fails
            # the same way.
            at = max(end_of_run(p, skip_run, input, at + w), at + w)
            continue
        end
        at += w
    end
end

"""
Tries the starts from `at` to `last` in order, as the plain search would: found with the start that matched, over when
the search is over without one, or else where the starts ran out.
"""
function try_starts(p::Program, st::State, input::Text16or8, at::Int, last::Int)
    len = length(input)
    first = p.first
    while at <= last && at <= len
        if !p.units && mid_pair(input, at)
            at += 1
            continue
        end
        if at == len
            first === nothing && run!(p, st, input, at) && return true, at, false
            return false, at, true
        end
        c = unit(input, at)
        r, w = Int(c), 1
        c >= 0x80 && ((r, w) = read_at(input, at, p.units))
        (first === nothing || r in first) && run!(p, st, input, at) && return true, at, false
        st.stop != STOP_NONE && return false, at, true
        at += w
    end
    return false, at, false
end

"The end of the run of members of the set from `at`."
function end_of_run(p::Program, set::CharSet, input::Text16or8, at::Int)
    n = length(input)
    while at < n
        c = unit(input, at)
        if c < 0x80
            has_ascii(set, c) || break
            at += 1
        else
            r, w = read_at(input, at, p.units)
            r in set || break
            at += w
        end
    end
    return at
end

"""
Whether the program matches at the position `start`: by the anchored automaton where the program has one and the text
it reads is ASCII, and otherwise by the matcher. The matcher keeps its choices on an explicit stack, so the depth of the
search is bounded by memory and not by the stack of the task. When it fails, every group and counter is back to the
value it had on entry. It counts its steps, and when a check says the match has reached a limit it returns false with
the reason in st.stop.
"""
function run!(p::Program, st::State, input::Text16or8, start::Int)
    dfa = p.anchored_dfa
    if dfa !== nothing
        end_ = find(dfa, input, start)
        if end_ >= 0
            st.end_ = end_
            return true
        end
        end_ == ADFA_NONE && return false
    end
    empty!(st.stack)
    return run_on!(p, st, st.stack, input, start)
end

function run_on!(p::Program, st::State, stack::Vector{Entry}, input::Text16or8, start::Int)
    insts = p.insts
    quick = p.quick
    # The text is matched by UTF-16 code unit (see units.jl).
    units = p.units
    len = length(input)
    caps, tmp, counts = st.caps, st.tmp, st.counts
    pc, pos = 0, start
    steps = st.steps
    # The match has taken the memory of failed places into use.
    memo = st.memo_on
    @inbounds while true
        steps -= 1
        if steps < 0
            if !check!(st, length(stack))
                st.steps = 0
                return false
            end
            steps = CHECK_EVERY
            memo = st.memo_on
        end
        i = insts[pc+1]
        op = i.op
        if op == OP_CHAR
            if pos < len
                c = unit(input, pos)
                if c < 0x80
                    if c == i.r
                        pos += 1
                        pc += 1
                        continue
                    end
                else
                    r, w = read_at(input, pos, units)
                    if r == i.r
                        pos += w
                        pc += 1
                        continue
                    end
                end
            end
        elseif op == OP_SET
            if pos < len
                set = i.set::CharSet
                c = unit(input, pos)
                if c < 0x80
                    if has_ascii(set, c)
                        pos += 1
                        pc += 1
                        continue
                    end
                else
                    r, w = read_at(input, pos, units)
                    if r in set
                        pos += w
                        pc += 1
                        continue
                    end
                end
            end
        elseif op == OP_LIT
            lit = lit_of(i, input)
            n = length(lit)
            if len - pos >= n && equal_at(input, pos, lit)
                pos += n
                pc += 1
                continue
            end
        elseif op == OP_CHAR_BACK || op == OP_SET_BACK
            if pos > 0
                c = unit(input, pos - 1)
                r, w = Int(c), 1
                c >= 0x80 && ((r, w) = read_last(input, pos, units))
                if op == OP_CHAR_BACK && r == i.r || op == OP_SET_BACK && r in (i.set::CharSet)
                    pos -= w
                    pc += 1
                    continue
                end
            end
        elseif op == OP_FAIL
        elseif op == OP_BOL
            if pos == 0
                pc += 1
                continue
            end
        elseif op == OP_EOL
            if pos == len
                pc += 1
                continue
            end
        elseif op == OP_WORD_BOUNDARY || op == OP_NOT_WORD_BOUNDARY
            before = pos > 0 && is_word_unit(unit(input, pos - 1))
            after = pos < len && is_word_unit(unit(input, pos))
            if (before != after) == (op == OP_WORD_BOUNDARY)
                pc += 1
                continue
            end
        elseif op == OP_LINE_START
            if pos == 0 || line_terminator_before(input, pos)
                pc += 1
                continue
            end
        elseif op == OP_LINE_END
            if pos == len || line_terminator_at(input, pos)
                pc += 1
                continue
            end
        elseif op == OP_WORD_BOUNDARY_FOLD || op == OP_NOT_WORD_BOUNDARY_FOLD
            before = pos > 0 && is_fold_word_rune(decode_last(input, pos)[1])
            after = pos < len && is_fold_word_rune(decode(input, pos)[1])
            if (before != after) == (op == OP_WORD_BOUNDARY_FOLD)
                pc += 1
                continue
            end
        elseif op == OP_JMP
            pc = i.x
            continue
        elseif op == OP_SPLIT
            # A place from which every way has failed before fails at once. The mark is under whatever comes of this
            # place, a choice or not, so that the place is remembered when it has all failed.
            if memo && i.m != 0
                idx = memo_index(p, st, i.m, pos)
                memo_has(st, idx) && @goto backtrack
                length(stack) < MAX_MARK_DEPTH && push!(stack, Entry(E_MARK, 0, idx))
            end
            # A way the next character rules out is not taken, and no choice is kept for it.
            if !allows(quick[i.y+1], input, pos)
                allows(quick[i.x+1], input, pos) || @goto backtrack
                pc = i.x
                continue
            end
            if !allows(quick[i.x+1], input, pos)
                pc = i.y
                continue
            end
            push!(stack, Entry(E_CHOICE, i.y, pos))
            pc = i.x
            continue
        elseif op == OP_SAVE_TMP
            a = i.a
            push!(stack, Entry(E_TMP, a, tmp[a+1]))
            tmp[a+1] = pos
            pc += 1
            continue
        elseif op == OP_CAPTURE
            a = i.a
            push!(stack, Entry(E_CAP, Int32(a), caps[2a+1], caps[2a+2]))
            if i.flag
                caps[2a+1], caps[2a+2] = pos, tmp[a+1]
            else
                caps[2a+1], caps[2a+2] = tmp[a+1], pos
            end
            pc += 1
            continue
        elseif op == OP_CLEAR
            steps -= i.b - i.a
            for g in i.a:i.b
                if caps[2g+1] != NONE
                    push!(stack, Entry(E_CAP, Int32(g), caps[2g+1], caps[2g+2]))
                    caps[2g+1], caps[2g+2] = NONE, NONE
                end
            end
            pc += 1
            continue
        elseif op == OP_BACKREF
            # A group that has not taken part matches the empty string.
            a = i.a
            from, to = caps[2a+1], caps[2a+2]
            if from == NONE
                pc += 1
                continue
            end
            n = to - from
            if len - pos >= n && equal_runs(input, pos, from, n) && whole(input, pos, pos + n)
                steps -= n >> 3
                pos += n
                pc += 1
                continue
            end
        elseif op == OP_BACKREF_BACK
            a = i.a
            from, to = caps[2a+1], caps[2a+2]
            if from == NONE
                pc += 1
                continue
            end
            n = to - from
            if pos >= n && equal_runs(input, pos - n, from, n) && whole(input, pos - n, pos)
                steps -= n >> 3
                pos -= n
                pc += 1
                continue
            end
        elseif op == OP_BACKREF_FOLD || op == OP_BACKREF_UNITS
            # A character at a time: to fold case, or because a group matched by code unit can begin or end between the
            # halves of a character, where its bytes do not say what it holds.
            a = i.a
            from, to = caps[2a+1], caps[2a+2]
            if from == NONE
                pc += 1
                continue
            end
            steps -= (to - from) >> 3
            at, ok = pos, true
            while from < to && ok
                want, w = read_at(input, from, units)
                from += w
                if at >= len
                    ok = false
                    break
                end
                got, w2 = read_at(input, at, units)
                at += w2
                ok = got == want || op == OP_BACKREF_FOLD && equal_ignoring_case(i.b, got, want, i.flag)
            end
            if ok
                pos = at
                pc += 1
                continue
            end
        elseif op == OP_BACKREF_FOLD_BACK || op == OP_BACKREF_UNITS_BACK
            a = i.a
            from, to = caps[2a+1], caps[2a+2]
            if from == NONE
                pc += 1
                continue
            end
            steps -= (to - from) >> 3
            at, ok = pos, true
            while from < to && ok
                want, w = read_last(input, to, units)
                to -= w
                if at == 0
                    ok = false
                    break
                end
                got, w2 = read_last(input, at, units)
                at -= w2
                ok = got == want ||
                     op == OP_BACKREF_FOLD_BACK && equal_ignoring_case(i.b, got, want, i.flag)
            end
            if ok
                pos = at
                pc += 1
                continue
            end
        elseif op == OP_LOOK
            # What follows a lookaround starts where the lookaround does, and so does the body of a lookahead.
            if allows(quick[pc+1], input, pos)
                push!(stack, Entry(i.flag ? E_LOOK_NEG : E_LOOK, i.x, pos))
                pc += 1
                continue
            end
        elseif op == OP_LOOK_OK
            # The body matched. A lookaround is atomic, so the choices made inside it are dropped. The undo entries stay,
            # because the groups it set remain set until something below this point is retried.
            f = length(stack)
            while stack[f].kind != E_LOOK
                f -= 1
            end
            pos = stack[f].pos
            keep = f
            for k in f+1:length(stack)
                if stack[k].kind >= E_TMP
                    stack[keep] = stack[k]
                    keep += 1
                end
            end
            resize!(stack, keep - 1)
            pc += 1
            continue
        elseif op == OP_LOOK_FAIL
            # The body of a negative lookaround matched, so the lookaround fails and everything it did is undone.
            while !isempty(stack)
                e = pop!(stack)
                e.kind == E_LOOK_NEG && break
                undo!(st, e)
            end
        elseif op == OP_REP
            at, n, floor = pos, 0, pos
            set = i.set
            if set !== nothing
                while n != i.max && at < len
                    c = unit(input, at)
                    if c < 0x80
                        has_ascii(set, c) || break
                        at += 1
                    else
                        r, w = read_at(input, at, units)
                        r in set || break
                        at += w
                    end
                    n += 1
                    n == i.min && (floor = at)
                end
            else
                while n != i.max && at < len
                    c = unit(input, at)
                    r, w = Int(c), 1
                    c >= 0x80 && ((r, w) = read_at(input, at, units))
                    r != i.r && break
                    at += w
                    n += 1
                    n == i.min && (floor = at)
                end
            end
            steps -= (at - pos) >> 3
            if n >= i.min
                if memo && i.m != 0
                    idx = memo_index(p, st, i.m, at)
                    if memo_has(st, idx)
                        # What follows the loop has failed from here before. The loop gives a character back.
                        at > floor && push!(stack, Entry(E_REP, Int32(pc + 1), at, floor))
                        @goto backtrack
                    end
                    at == floor && length(stack) < MAX_MARK_DEPTH && push!(stack, Entry(E_MARK, 0, idx))
                end
                at > floor && push!(stack, Entry(E_REP, Int32(pc + 1), at, floor))
                pos = at
                pc += 1
                continue
            end
        elseif op == OP_REP_LAZY
            at, n = pos, 0
            while n < i.min
                w = one_width(i, input, at, units)
                w == 0 && break
                at += w
                n += 1
            end
            steps -= n >> 3
            if n == i.min
                if memo && i.m != 0
                    idx = memo_index(p, st, i.m, at)
                    if memo_has(st, idx)
                        # What follows the loop has failed from here before. The loop takes one more character.
                        n != i.max && push!(stack, Entry(E_REP_LAZY, Int32(pc), at, n))
                        @goto backtrack
                    end
                    n == i.max && length(stack) < MAX_MARK_DEPTH && push!(stack, Entry(E_MARK, 0, idx))
                end
                n != i.max && push!(stack, Entry(E_REP_LAZY, Int32(pc), at, n))
                pos = at
                pc += 1
                continue
            end
        elseif op == OP_LOOP_INIT
            a = i.a
            push!(stack, Entry(E_COUNTER, Int32(a), counts[2a+1], counts[2a+2]))
            counts[2a+1], counts[2a+2] = 0, NONE
            pc += 1
            continue
        elseif op == OP_LOOP
            a = i.a
            n = counts[2a+1]
            minc, nd, left, iter = i.min, need_of(i, input), len - pos, iter_of(i, input)
            # Fewer units are left than any way from here to a match consumes: what follows the loop, and the
            # iterations it has still to make.
            (left < nd || n < minc && iter != 0 && left - nd < (minc - n) * iter) && @goto backtrack
            # Once the minimum is met, ECMA-262 rejects an iteration that consumed nothing. That is what stops a loop
            # over a body that can be empty.
            n > minc && pos == counts[2a+2] && @goto backtrack
            if n < minc
                pc += 1
                continue
            end
            if i.max >= 0 && n >= i.max
                pc = i.x
                continue
            end
            # The loop may be left or entered from here. A place from which both have failed before fails at once.
            if memo && i.m != 0
                idx = memo_index(p, st, i.m, pos)
                memo_has(st, idx) && @goto backtrack
                length(stack) < MAX_MARK_DEPTH && push!(stack, Entry(E_MARK, 0, idx))
            end
            if !allows(quick[i.x+1], input, pos)
                # The next character rules out leaving the loop, so there is no choice.
                pc += 1
            elseif !allows(quick[pc+2], input, pos)
                pc = i.x
            elseif i.flag
                push!(stack, Entry(E_CHOICE, pc + 1, pos))
                pc = i.x
            else
                push!(stack, Entry(E_CHOICE, i.x, pos))
                pc += 1
            end
            continue
        elseif op == OP_LOOP_ITER
            a = i.a
            push!(stack, Entry(E_COUNTER, Int32(a), counts[2a+1], counts[2a+2]))
            counts[2a+1] += 1
            counts[2a+2] = pos
            pc += 1
            continue
        elseif op == OP_MATCH
            st.steps = steps
            st.end_ = pos
            return true
        end
        @label backtrack
        # The instruction failed. Take up the most recent choice, undoing what was recorded since.
        while true
            if isempty(stack)
                st.steps = steps
                return false
            end
            top = length(stack)
            e = stack[top]
            kind = e.kind
            if kind == E_CHOICE
                pc, pos = Int(e.pc), e.pos
                pop!(stack)
                break
            elseif kind == E_REP
                # What followed the loop from the position it stood at has failed.
                rep = insts[e.pc]
                marked = memo && rep.m != 0
                marked && memo_set!(st, memo_index(p, st, rep.m, e.pos))
                # Give back the last character taken. The characters between a and pos were decoded going forward, and
                # decoding the last of them going backward finds the same boundary.
                at = e.pos - give_back(input, e.a, e.pos, units)
                if is_utf8(input) && !isempty(rep.back) && at > e.a && !allows(quick[e.pc+1], input, at)
                    # What follows the loop can only start with one of a few ASCII bytes: the last of them before here
                    # is found by a search back, and the positions after it are passed over at once.
                    at = last_of_back(input, e.a, at, rep.back)
                end
                stack[top] = Entry(e.kind, e.pc, at, e.a)
                pc, pos = Int(e.pc), at
                last = at <= e.a
                # A position from which what follows the loop cannot go on is passed over, and so is one from which it
                # has failed before.
                pass = !allows(quick[pc+1], input, pos)
                if marked && !pass
                    idx = memo_index(p, st, rep.m, pos)
                    if memo_has(st, idx)
                        pass = true
                    elseif last
                        # The loop has nothing more to give back. The entry stays to note this last way.
                        stack[top] = Entry(E_MARK, 0, idx)
                        break
                    end
                end
                last && pop!(stack)
                if pass
                    steps -= 1
                    continue
                end
                break
            elseif kind == E_REP_LAZY
                # What followed the loop from the position it stood at has failed.
                rep = insts[e.pc+1]
                marked = memo && rep.m != 0
                marked && memo_set!(st, memo_index(p, st, rep.m, e.pos))
                w = one_width(rep, input, e.pos, units)
                if w == 0
                    pop!(stack)
                    continue
                end
                at, taken = e.pos + w, e.a + 1
                stack[top] = Entry(e.kind, e.pc, at, taken)
                pc, pos = Int(e.pc) + 1, at
                last = taken == rep.max
                if marked
                    idx = memo_index(p, st, rep.m, pos)
                    if memo_has(st, idx)
                        last && pop!(stack)
                        steps -= 1
                        continue
                    end
                    if last
                        stack[top] = Entry(E_MARK, 0, idx)
                        break
                    end
                end
                last && pop!(stack)
                break
            elseif kind == E_MARK
                # Every way from a memo point has failed.
                memo_set!(st, e.pos)
                pop!(stack)
            elseif kind == E_LOOK
                # The body of a positive lookaround has no way left to match.
                pop!(stack)
            elseif kind == E_LOOK_NEG
                # The body of a negative lookaround has no way to match, so the lookaround holds.
                pc, pos = Int(e.pc), e.pos
                pop!(stack)
                break
            else
                undo!(st, e)
                pop!(stack)
            end
        end
    end
end

"""
The width of the character at the position `at` when the instruction's character or class matches it, and 0
otherwise. The character is a code unit with `units` set.
"""
@inline function one_width(i::Inst, input::Text16or8, at::Int, units::Bool)
    at >= length(input) && return 0
    c = unit(input, at)
    r, w = Int(c), 1
    c >= 0x80 && ((r, w) = read_at(input, at, units))
    return one_of(i, r, w)
end
