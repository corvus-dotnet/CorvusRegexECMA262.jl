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
whether it was found. When it finds one and `caps` is given, `caps` receives the start and end of each group the program
records, or -1 for a group that did not take part. With a limit (in nanoseconds) the match is abandoned when it has run
for longer than that, or when its stack has reached MAX_STACK, and the error says which.
"""
function exec(p::Program, input::Text16or8, start::Int, sticky::Bool, limit::Int, caps::Union{Nothing,Vector{Int}})
    st = take_state()
    reset!(st, p, length(input), limit)
    from, found = search(p, st, input, start, sticky)
    to = st.end_
    stop = st.stop
    found && caps !== nothing && copyto!(caps, st.caps)
    release!(st)
    give_state(st)
    throw_stop(stop, limit)
    return from, to, found
end

function search(p::Program, st::State, input::Text16or8, start::Int, sticky::Bool)
    len = length(input)
    n = need(p, input)
    (start > len || len - start < n) && return 0, false
    if sticky || p.anchored
        p.anchored && start > 0 && return 0, false
        return start, run!(p, st, input, start)
    end
    return scan(p, st, input, start, n)
end

"Tries every position from `start` that the first set allows, until one matches."
function scan(p::Program, st::State, input::Text16or8, start::Int, n::Int)
    len = length(input)
    units = p.units
    first = p.first
    at = start
    while true
        len - at < n && return 0, false
        at == len && return at, first === nothing && run!(p, st, input, at)
        c = unit(input, at)
        r, w = Int(c), 1
        c >= 0x80 && ((r, w) = read_at(input, at, units))
        (first === nothing || r in first) && run!(p, st, input, at) && return at, true
        st.stop != STOP_NONE && return 0, false
        at += w
    end
end

"""
Whether the program matches at the position `start`. It keeps its choices on an explicit stack, so the depth of the
search is bounded by memory and not by the stack of the task. When it fails, every group and counter is back to the
value it had on entry. It counts its steps, and when a check says the match has reached a limit it returns false with
the reason in st.stop.
"""
function run!(p::Program, st::State, input::Text16or8, start::Int)
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
                ok = got == want || op == OP_BACKREF_FOLD && canonicalize(got, i.flag) == canonicalize(want, i.flag)
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
                     op == OP_BACKREF_FOLD_BACK && canonicalize(got, i.flag) == canonicalize(want, i.flag)
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
