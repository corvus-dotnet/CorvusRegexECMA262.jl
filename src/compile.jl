# The compiler: a syntax tree to a program of the backtracking matcher, with what the matcher needs to give up early
# (compile.rs).
#
# Instructions are numbered from 0, as in the crate, and a jump names the number of the instruction it goes to; the
# instruction numbered pc is `insts[pc + 1]`.

@enum Op::UInt8 begin
    # OP_CHAR and OP_SET consume one code point going forward. The BACK forms consume the one before the position,
    # which is how the body of a lookbehind runs.
    OP_CHAR
    OP_CHAR_BACK
    OP_SET
    OP_SET_BACK
    # Consumes a run of literal units going forward.
    OP_LIT
    OP_FAIL
    OP_BOL
    OP_EOL
    OP_WORD_BOUNDARY
    OP_NOT_WORD_BOUNDARY
    # ^ and $ with the m modifier. The FOLD forms of the word boundaries and of the backreferences belong to a
    # case-insensitive group.
    OP_LINE_START
    OP_LINE_END
    OP_WORD_BOUNDARY_FOLD
    OP_NOT_WORD_BOUNDARY_FOLD
    OP_JMP
    # Continues at x and leaves y as the alternative.
    OP_SPLIT
    # OP_SAVE_TMP notes where a group was entered. OP_CAPTURE records the group once it has closed.
    OP_SAVE_TMP
    OP_CAPTURE
    # Resets the groups a to b, as ECMA-262 does at the start of each iteration of a quantified body.
    OP_CLEAR
    OP_BACKREF
    OP_BACKREF_BACK
    OP_BACKREF_FOLD
    OP_BACKREF_FOLD_BACK
    # Compare a group a code unit at a time, for a pattern matched by code unit.
    OP_BACKREF_UNITS
    OP_BACKREF_UNITS_BACK
    # OP_LOOK opens a lookaround. OP_LOOK_OK ends the body of a positive one and OP_LOOK_FAIL the body of a negative
    # one.
    OP_LOOK
    OP_LOOK_OK
    OP_LOOK_FAIL
    # Repeat one character or class without entering the general loop.
    OP_REP
    OP_REP_LAZY
    # Run a counted or possibly empty quantified body.
    OP_LOOP_INIT
    OP_LOOP
    OP_LOOP_ITER
    OP_MATCH
end

"One instruction of the backtracking matcher."
mutable struct Inst
    op::Op
    # Marks a lazy OP_LOOP, a backward OP_CAPTURE, a negative OP_LOOK, and an OP_BACKREF_FOLD that folds case as the u
    # flag grammar does.
    flag::Bool
    r::Int
    set::Union{Nothing,CharSet}
    # The literal run of an OP_LIT, in UTF-8 and in UTF-16.
    lit8::Vector{UInt8}
    lit16::Vector{UInt16}
    # For an OP_REP, the ASCII bytes (up to three) what follows it can start with, when those are all it can start
    # with: its give-back looks for them with a search back (see set_back!).
    back::Vector{UInt8}
    # Jump targets.
    x::Int
    y::Int
    # A group, a loop or a range of groups, depending on the instruction.
    a::Int
    b::Int
    # Bound a repetition. A max of -1 is no bound.
    min::Int
    max::Int
    # need8 is the least number of bytes of text that every way from this instruction to a match consumes going
    # forward (see set_needs!). It is set for an OP_LOOP, and counts none of the iterations the loop has still to make.
    # need16 is the same in UTF-16 code units.
    need8::Int
    need16::Int
    # The least number of bytes one iteration of the body of an OP_LOOP consumes going forward, and of UTF-16 code
    # units.
    iter8::Int
    iter16::Int
    # The number of the instruction's memo point, counted from 1, or 0 when it has none (see MemoPoint). It is set for
    # an OP_SPLIT, an OP_LOOP, an OP_REP and an OP_REP_LAZY.
    m::Int
end

const NO_BYTES = UInt8[]

function Inst(op::Op; flag=false, r=0, set=nothing, lit8=NO_BYTES, lit16=UInt16[], x=0, y=0, a=0, b=0, min=0, max=0,
    iter8=0, iter16=0, m=0)
    Inst(op, flag, r, set, lit8, lit16, NO_BYTES, x, y, a, b, min, max, 0, 0, iter8, iter16, m)
end

# The number of loops whose state a memo point can tell apart.
const MAX_MEMO_LOOPS = 2

"""
A place where the matcher makes a choice and can remember that the choice has failed: a split, a loop that may be
entered or left, and what follows a single character loop that gives characters back or takes more. Whether a way from
such a place leads to a match depends on the place and the position alone when nothing else the matcher keeps can
change what follows. So a pattern with a backreference has no memo points (what a group holds changes what follows),
and neither has a place inside a loop that counts its iterations up to a bound. Inside a loop with no upper bound and a
least count of zero or one, one thing more decides what follows: whether the loop would refuse the iteration as empty
if it ended here. That is one bit for each such loop the place is in (`loops`, innermost last, -1 for none), and a place
in more than MAX_MEMO_LOOPS of them has no memo point.
"""
struct MemoPoint
    loops::NTuple{MAX_MEMO_LOOPS,Int}
    mins::NTuple{MAX_MEMO_LOOPS,Int}
end

"""
One counted loop that the instruction being written is inside of: its number, its least count, and whether its state
is one bit to a memo point (no upper bound, and a least count of zero or one).
"""
struct LoopContext
    loop::Int
    min::Int
    simple::Bool
end

"""
What can come next on a way from an instruction to the end of its match, which is the end of the pattern or of the
lookaround the instruction is in. The matcher looks at it before it takes a way: when the next character of the text
is none that the way can start with, and the way cannot end without one, the way fails, so it is not taken, and where
it was one of two no choice is kept for it. V8 makes the same check ("quick check") at its choices. It is what keeps a
choice between ways that need different characters from being a choice.

`ascii` is the characters below 128 a way can consume next, and `other` says it can consume a character that is not
ASCII. `mid` says a way reaches the end of its match consuming nothing more while text is left, and `end` that one does
at the end of the text.
"""
struct Quick
    ascii0::UInt64
    ascii1::UInt64
    other::Bool
    mid::Bool
    end_::Bool
end

const QUICK_NONE = Quick(0, 0, false, false, false)
const QUICK_ALL = Quick(typemax(UInt64), typemax(UInt64), true, true, true)

"Whether a way can go on from the position."
@inline function allows(q::Quick, input::Text16or8, pos::Int)
    pos >= length(input) && return q.end_
    q.mid && return true
    c = unit(input, pos)
    if c < 0x80
        word = c < 64 ? q.ascii0 : q.ascii1
        return (word >> (c & 63)) & 1 != 0
    end
    return q.other
end

function add_rune(q::Quick, r::Int)
    if 0 <= r < 0x80
        r < 64 ? Quick(q.ascii0 | UInt64(1) << r, q.ascii1, q.other, q.mid, q.end_) :
        Quick(q.ascii0, q.ascii1 | UInt64(1) << (r - 64), q.other, q.mid, q.end_)
    else
        Quick(q.ascii0, q.ascii1, true, q.mid, q.end_)
    end
end

function add_set(q::Quick, s::CharSet)
    other = q.other || !isempty(s.ranges) && s.ranges[end] >= 0x80
    Quick(q.ascii0 | s.ascii[1], q.ascii1 | s.ascii[2], other, q.mid, q.end_)
end

quick_union(q::Quick, o::Quick) =
    Quick(q.ascii0 | o.ascii0, q.ascii1 | o.ascii1, q.other || o.other, q.mid || o.mid, q.end_ || o.end_)

"A pattern compiled for the backtracking matcher."
mutable struct Program
    insts::Vector{Inst}
    # The number of groups the program records (every capturing group, or those some backreference names), and the
    # number of counted loops.
    groups::Int
    loops::Int
    # The pattern was read without the u flag, so the text is matched by UTF-16 code unit (see units.jl).
    units::Bool
    # Every match starts at the start of the text.
    anchored::Bool
    # The least number of bytes a match consumes (see set_needs!), and of UTF-16 code units.
    need8::Int
    need16::Int
    # The memo points of the program (see MemoPoint).
    points::Vector{MemoPoint}
    # For each instruction, which characters can come next on a way from it to the end of its match (see set_quick).
    quick::Vector{Quick}
    # Every code point a match can start with, or nothing when a match can be empty or when the set is not known.
    first::Union{Nothing,CharSet}
    # How the search finds where a match can start (see search.jl).
    search::Search
    # The anchored automaton that finds where a match from a start ends, for a program that records no group and needs
    # no backtracking (see adfa.jl).
    anchored_dfa::Union{Nothing,AnchoredDfa}
    # The tree of a pattern whose search tries every start its first set allows, from which the forward automaton (see
    # build_forward_dfa) is built on the first search that wants it: `missing` until then, then the automaton or
    # nothing.
    forward_root::Union{Nothing,Node}
    @atomic forward_dfa::Union{Missing,Nothing,AnchoredDfa}
    # For the same patterns, the window of positions read one unit at a time before the first set is searched for (see
    # SkipWin).
    skip::Union{Nothing,SkipWin}
    # For a pattern every match of which starts with one literal (a window at distance 0 of one literal over UTF-8), the
    # anchored automaton's states after it (see after), and its length: an occurrence goes on from there, its units not
    # read again.
    after_literal::Union{Nothing,NTuple{4,UInt32}}
    after_length::Int
end

"The forward automaton, built on the first search that wants it, or nothing when there is none."
function forward(p::Program)
    p.forward_root === nothing && return nothing
    d = @atomic p.forward_dfa
    d === missing || return d
    built = build_forward_dfa(p.forward_root)
    @atomic p.forward_dfa = built
    return built
end

"Whether a tree nests fewer than `limit` levels."
function shallower_than(n::Node, limit::Int)
    limit <= 0 && return false
    return all(s -> shallower_than(s, limit - 1), n.subs)
end

"The least number of units of the text a match consumes."
@inline need(p::Program, ::Bytes) = p.need8
@inline need(p::Program, ::Units) = p.need16

mutable struct Compiler
    insts::Vector{Inst}
    # A capturing group's number to its slot (from 0), for the groups that are recorded.
    tracked::Dict{Int,Int}
    loops::Int
    # The pattern was read with the u flag grammar, which decides how a backreference folds case.
    unicode::Bool
    # memo says the pattern has no backreference, so its choices can have memo points. open lists the counted loops
    # around the instruction being written, outermost first, inside the innermost lookaround: what a lookaround's body
    # does depends on nothing outside it. points collects the memo points.
    memo::Bool
    open::Vector{LoopContext}
    points::Vector{MemoPoint}
end

"""
Compiles a tree, changing it in place. With `groups` at 0 or more the program records every one of that many capturing
groups, group g in slot g - 1, so that a match can report what each captured; with `groups` below 0, only the groups
some backreference names.
"""
function compile_program(root::Node, unicode::Bool, groups::Int)
    root = simplify(root, Int[])
    c = Compiler(Inst[], Dict{Int,Int}(), 0, unicode, false, LoopContext[], MemoPoint[])
    referenced = Int[]
    collect_backrefs!(referenced, root)
    # A choice can be remembered to have failed only where what a group holds cannot change what follows.
    c.memo = isempty(referenced)
    if groups >= 0
        for g in 1:groups
            c.tracked[g] = g - 1
        end
    else
        # Slots follow group order, so the groups inside any one subtree take a contiguous range of slots.
        for (slot, g) in enumerate(sort!(unique(referenced)))
            c.tracked[g] = slot - 1
        end
    end
    emit!(c, root, false)
    add!(c, Inst(OP_MATCH))
    insts = c.insts
    need8, need16 = set_needs!(insts)
    q = set_quick(insts)
    set_back!(insts, q)
    anchored = starts_at_bol(root)
    groups_kept = length(c.tracked)
    backrefs = !isempty(referenced)
    anchored_dfa = groups_kept == 0 && !backrefs ? build_adfa(root) : nothing
    first = nothing
    search = Search()
    forward_root, skip, after_literal, after_length = nothing, nothing, nothing, 0
    if !anchored
        pairs = Int[]
        nullable_first, known = first_chars!(pairs, root)
        known && !nullable_first && (first = CharSet(pairs))
        search = plan_search(root, backrefs, first, !unicode)
        if search.plan == PLAN_WINDOWS && search.hi == 0 && anchored_dfa !== nothing && search.literals.single8 !== nothing
            literal = search.literals.single8
            rows = after(anchored_dfa, literal)
            if rows !== nothing
                after_literal, after_length = rows, length(literal)
            end
        end
        if !NO_SEARCH[] && !backrefs && shallower_than(root, 64) && search.plan == PLAN_SCAN && search.shape == SHAPE_NONE
            forward_root = root
            skip = skip_window(root)
        end
    end
    return Program(insts, groups_kept, c.loops, !unicode, anchored, need8, need16, c.points, q, first, search,
        anchored_dfa, forward_root, missing, skip, after_literal, after_length)
end

"""
The tree with two rewrites, both of which V8 makes. Neither changes what the pattern matches or what any group holds.
Without them a pattern can take time exponential in its counts for no reason that ECMA-262 gives.

A backreference to a group it is inside of is the empty string. The group is not set until it closes, and the
repetition around a group clears it at the start of each iteration, so inside the group it is never set.

A repetition whose body cannot consume a character, such as (?:\\b|(?=a)|){4,5}, is the body once when its minimum is
one or more, and nothing when its minimum is zero. Every iteration of such a body is empty. ECMA-262 refuses an empty
iteration after the minimum, so the iterations are exactly the minimum. Each of them starts with the groups of the body
cleared and at the same position, so what the last one can do does not depend on the ones before it, and the ways
through the last one come in the same order whatever the others chose. Run as written, the matcher would try every
combination of the ways through every iteration.
"""
function simplify(n::Node, open::Vector{Int})
    if n.kind == N_BACKREF
        all(g -> g in open, n.groups) && return Node(N_EMPTY)
        return n
    end
    isempty(n.subs) && return n
    opened = n.kind == N_GROUP && n.group > 0
    opened && push!(open, n.group)
    for k in eachindex(n.subs)
        n.subs[k] = simplify(n.subs[k], open)
    end
    opened && pop!(open)
    if n.kind == N_CAT && any(s -> s.kind == N_CAT, n.subs)
        # A sequence inside a sequence (a written-out repetition) is the same sequence: flat, so that what reads the
        # terms (the searches, the first characters) sees them all.
        flat = Node[]
        for sub in n.subs
            sub.kind == N_CAT ? append!(flat, sub.subs) : push!(flat, sub)
        end
        n.subs = flat
    end
    if n.kind == N_REPEAT && n.max != 0 && !consumes(n.subs[1])
        n.min == 0 && return Node(N_EMPTY)
        return n.subs[1]
    end
    if UNROLLING[] && n.kind == N_REPEAT && n.min == n.max && 2 <= n.max <= 32 &&
       (n.subs[1].kind == N_SET || n.subs[1].kind == N_CHAR)
        # An exact count of one character or class is that many of it in a row: a straight run of tests without a
        # loop's counting, which pays where a search tries the run at every occurrence of a literal after it
        # ([a-q][^u-z]{13}x). (The .NET reference engine's Simplify.)
        return unroll(n)
    end
    if UNROLLING[] && n.kind == N_REPEAT && 1 <= n.max <= 4 && n.min >= 1 && !nullable(n.subs[1]) &&
       !has_capture(n.subs[1]) && tree_size(n.subs[1]) <= 32 &&
       (n.subs[1].kind == N_GROUP || n.subs[1].kind == N_ALT || n.subs[1].kind == N_CAT)
        # A small counted repetition of a body that holds no group and cannot be empty is the body written out, with
        # the copies beyond the least count optional one inside the other: the same matches in the same order, without
        # a loop's counting. A body of one character stays a counted loop, which the matcher runs without choices.
        return unroll(n)
    end
    return n
end

# Whether small counted repetitions are written out. The tests of the loops' needs and memo points turn it off, to
# keep every counted repetition a loop.
const UNROLLING = Ref(true)

"""
Writes out a counted repetition (see simplify): X{2,4} is X X (X (X)?)?, the optional copies one inside the other, so
that a copy is tried only when the one before it matched.
"""
function unroll(n::Node)
    body = n.subs[1]
    terms = Node[]
    for _ in 1:n.min
        push!(terms, clone_node(body))
    end
    if n.max > n.min
        optional = nothing
        for _ in n.min:n.max-1
            inner = clone_node(body)
            optional === nothing || (inner = with_subs(N_CAT, inner, optional))
            optional = repeat_node(inner, 0, 1, n.lazy)
        end
        push!(terms, optional)
    end
    length(terms) == 1 && return terms[1]
    flat = Node[]
    for t in terms
        t.kind == N_CAT ? append!(flat, t.subs) : push!(flat, t)
    end
    return with_subs(N_CAT, flat...)
end

"A deep copy of a tree. A class is immutable, so the copy shares it."
function clone_node(n::Node)
    Node(n.kind, n.r, n.set, Node[clone_node(s) for s in n.subs], n.min, n.max, n.lazy, n.group, copy(n.groups),
        copy(n.name), n.fold, n.behind, n.negative)
end

"Whether a node holds a capturing group, a backreference or a lookaround."
has_capture(n::Node) = n.kind == N_GROUP && n.group > 0 || n.kind == N_BACKREF || n.kind == N_LOOK ||
                       any(has_capture, n.subs)

"The number of nodes of a tree."
tree_size(n::Node) = 1 + sum(tree_size, n.subs; init=0)

"Whether n can match one character or more. It errs towards true."
function consumes(n::Node)
    n.kind in (N_CHAR, N_SET, N_BACKREF) && return true
    n.kind in (N_CAT, N_ALT, N_GROUP) && return any(consumes, n.subs)
    n.kind == N_REPEAT && return n.max != 0 && consumes(n.subs[1])
    return false
end

function collect_backrefs!(out::Vector{Int}, n::Node)
    n.kind == N_BACKREF && append!(out, n.groups)
    for sub in n.subs
        collect_backrefs!(out, sub)
    end
end

"Adds an instruction and returns its number."
function add!(c::Compiler, i::Inst)
    push!(c.insts, i)
    return length(c.insts) - 1
end

"The number of the next instruction."
pc(c::Compiler) = length(c.insts)

inst(c::Compiler, k::Int) = c.insts[k+1]

"""
The number of a new memo point for an instruction written here, or 0 when a choice here cannot be remembered.
"""
function point!(c::Compiler)
    (!c.memo || length(c.open) > MAX_MEMO_LOOPS) && return 0
    loops = [-1, -1]
    mins = [0, 0]
    for (k, l) in enumerate(c.open)
        l.simple || return 0
        loops[k], mins[k] = l.loop, l.min
    end
    push!(c.points, MemoPoint((loops[1], loops[2]), (mins[1], mins[2])))
    return length(c.points)
end

"The first and last slot of the tracked groups inside n, and false when it has none."
function group_range(c::Compiler, n::Node)
    lo, hi, found = 0, 0, false
    function walk(n::Node)
        if n.kind == N_GROUP && n.group > 0
            t = get(c.tracked, n.group, nothing)
            if t !== nothing
                if !found
                    lo, hi, found = t, t, true
                else
                    lo, hi = min(lo, t), max(hi, t)
                end
            end
        end
        foreach(walk, n.subs)
    end
    walk(n)
    return lo, hi, found
end

"""
Writes the instructions for n. With `back` set the instructions match right to left, as the body of a lookbehind must.
"""
function emit!(c::Compiler, n::Node, back::Bool)
    k = n.kind
    if k == N_EMPTY
    elseif k == N_CHAR
        add!(c, Inst(back ? OP_CHAR_BACK : OP_CHAR; r=n.r))
    elseif k == N_SET
        if isempty(n.set)
            add!(c, Inst(OP_FAIL))
        else
            add!(c, Inst(back ? OP_SET_BACK : OP_SET; set=n.set))
        end
    elseif k == N_CAT
        if back
            for sub in Iterators.reverse(n.subs)
                emit!(c, sub, true)
            end
            return
        end
        i = 1
        while i <= length(n.subs)
            # A run of literal characters becomes one comparison of units.
            j = i
            lit = Int[]
            while j <= length(n.subs) && n.subs[j].kind == N_CHAR && literal_rune(n.subs[j].r)
                push!(lit, n.subs[j].r)
                j += 1
            end
            if j - i >= 2
                s = String(Char.(lit))
                add!(c, Inst(OP_LIT; lit8=Vector{UInt8}(codeunits(s)), lit16=transcode(UInt16, s)))
                i = j
                continue
            end
            emit!(c, n.subs[i], false)
            i += 1
        end
    elseif k == N_ALT
        jumps = Int[]
        for (i, sub) in enumerate(n.subs)
            if i == length(n.subs)
                emit!(c, sub, back)
                break
            end
            m = point!(c)
            split = add!(c, Inst(OP_SPLIT; m=m))
            inst(c, split).x = pc(c)
            emit!(c, sub, back)
            push!(jumps, add!(c, Inst(OP_JMP)))
            inst(c, split).y = pc(c)
        end
        for j in jumps
            inst(c, j).x = pc(c)
        end
    elseif k == N_GROUP
        t = n.group != 0 ? get(c.tracked, n.group, nothing) : nothing
        if t === nothing
            emit!(c, n.subs[1], back)
            return
        end
        add!(c, Inst(OP_SAVE_TMP; a=t))
        emit!(c, n.subs[1], back)
        add!(c, Inst(OP_CAPTURE; a=t, flag=back))
    elseif k == N_BOL
        add!(c, Inst(OP_BOL))
    elseif k == N_EOL
        add!(c, Inst(OP_EOL))
    elseif k == N_LINE_START
        add!(c, Inst(OP_LINE_START))
    elseif k == N_LINE_END
        add!(c, Inst(OP_LINE_END))
    elseif k == N_WORD_BOUNDARY
        add!(c, Inst(n.fold ? OP_WORD_BOUNDARY_FOLD : OP_WORD_BOUNDARY))
    elseif k == N_NOT_WORD_BOUNDARY
        add!(c, Inst(n.fold ? OP_NOT_WORD_BOUNDARY_FOLD : OP_NOT_WORD_BOUNDARY))
    elseif k == N_BACKREF
        o = if n.fold && back
            OP_BACKREF_FOLD_BACK
        elseif n.fold
            OP_BACKREF_FOLD
        elseif back && !c.unicode
            OP_BACKREF_UNITS_BACK
        elseif back
            OP_BACKREF_BACK
        elseif !c.unicode
            OP_BACKREF_UNITS
        else
            OP_BACKREF
        end
        # When several groups share the name, at most one has taken part, and the others match the empty string. So
        # matching each in turn matches the one that took part.
        for g in n.groups
            add!(c, Inst(o; a=c.tracked[g], flag=c.unicode))
        end
    elseif k == N_LOOK
        look = add!(c, Inst(OP_LOOK; flag=n.negative))
        # Whether the body matches depends on nothing outside it.
        outer = c.open
        c.open = LoopContext[]
        emit!(c, n.subs[1], n.behind)
        c.open = outer
        add!(c, Inst(n.negative ? OP_LOOK_FAIL : OP_LOOK_OK))
        inst(c, look).x = pc(c)
    elseif k == N_REPEAT
        emit_repeat!(c, n, back)
    end
    return
end

function emit_body!(c::Compiler, body::Node, back::Bool, lo::Int, hi::Int, clear::Bool)
    clear && add!(c, Inst(OP_CLEAR; a=lo, b=hi))
    emit!(c, body, back)
end

"A choice between entering the body and leaving the loop, to be completed by set_split!."
split!(c::Compiler) = add!(c, Inst(OP_SPLIT; m=point!(c)))

"Completes a split in the order the quantifier prefers."
function set_split!(c::Compiler, lazy::Bool, at::Int, enter::Int, exit::Int)
    i = inst(c, at)
    if lazy
        i.x, i.y = exit, enter
    else
        i.x, i.y = enter, exit
    end
end

function emit_repeat!(c::Compiler, n::Node, back::Bool)
    body = n.subs[1]
    n.max == 0 && return
    minc, maxc = n.min, n.max
    if !back && (body.kind == N_CHAR || body.kind == N_SET && !isempty(body.set))
        add!(c, Inst(n.lazy ? OP_REP_LAZY : OP_REP; r=body.r, set=body.set, min=minc, max=maxc, m=point!(c)))
        return
    end
    lo, hi, clear = group_range(c, body)
    # A body that always consumes something needs no check for empty iterations, so the unbounded forms and the
    # optional form are plain choices.
    if !nullable(body)
        if n.min == 0 && n.max == UNBOUNDED
            at = split!(c)
            enter = pc(c)
            emit_body!(c, body, back, lo, hi, clear)
            add!(c, Inst(OP_JMP; x=at))
            set_split!(c, n.lazy, at, enter, pc(c))
            return
        elseif n.min == 1 && n.max == UNBOUNDED
            enter = pc(c)
            emit_body!(c, body, back, lo, hi, clear)
            at = split!(c)
            set_split!(c, n.lazy, at, enter, pc(c))
            return
        elseif n.min == 0 && n.max == 1
            at = split!(c)
            enter = pc(c)
            emit_body!(c, body, back, lo, hi, clear)
            set_split!(c, n.lazy, at, enter, pc(c))
            return
        end
    end
    k = c.loops
    c.loops += 1
    add!(c, Inst(OP_LOOP_INIT; a=k))
    iter8, iter16 = back ? (0, 0) : (min_length(body, true), min_length(body, false))
    simple = maxc == UNBOUNDED && minc <= 1
    # The loop is left or entered from here, and what follows either depends on the loops around this one.
    point = simple ? point!(c) : 0
    loop = add!(c, Inst(OP_LOOP; a=k, min=minc, max=maxc, flag=n.lazy, iter8=iter8, iter16=iter16, m=point))
    add!(c, Inst(OP_LOOP_ITER; a=k))
    push!(c.open, LoopContext(k, minc, simple))
    emit_body!(c, body, back, lo, hi, clear)
    pop!(c.open)
    add!(c, Inst(OP_JMP; x=loop))
    inst(c, loop).x = pc(c)
end

# The need of an instruction from which no way leads to a match. Every need is capped at it.
const NO_MATCH = 1 << 30

"The number of bytes of UTF-8 a code point takes."
rune_len(r::Int) = r <= 0x7F ? 1 : r <= 0x7FF ? 2 : r <= 0xFFFF ? 3 : 4

"""
The least number of units a match of n consumes, capped at NO_MATCH: bytes of UTF-8 with `utf8set`, and UTF-16 code
units without it. Like the needs, it counts a character as its units when the matcher compares units for it and as one
unit otherwise, so it can only be too small.
"""
function min_length(n::Node, utf8set::Bool)
    k = n.kind
    if k == N_CHAR
        literal_rune(n.r) || return 1
        utf8set && return rune_len(n.r)
        return n.r > 0xFFFF ? 2 : 1
    elseif k == N_SET
        return isempty(n.set) ? NO_MATCH : 1
    elseif k == N_CAT
        total = 0
        for sub in n.subs
            total += min_length(sub, utf8set)
            total >= NO_MATCH && return NO_MATCH
        end
        return total
    elseif k == N_ALT
        least = NO_MATCH
        for sub in n.subs
            least = min(least, min_length(sub, utf8set))
        end
        return least
    elseif k == N_GROUP
        return min_length(n.subs[1], utf8set)
    elseif k == N_REPEAT
        return times_need(n.min, min_length(n.subs[1], utf8set))
    end
    return 0
end

"count times need, capped at NO_MATCH."
function times_need(count::Int, need::Int)
    (count == 0 || need == 0) && return 0
    (need >= NO_MATCH || count >= NO_MATCH ÷ need) && return NO_MATCH
    return count * need
end

"""
Works out, for every instruction, the least number of bytes of text that any way from it to a match consumes going
forward, and writes it into the counted loops. It returns the need of the whole program. The matcher gives up at a
counted loop when fewer bytes than that are left, as V8 does at every choice. A loop whose iterations can be empty
would otherwise try every combination of its ways at a position from which the rest of the pattern cannot match at
all.

A counted loop that is entered needs its least count of iterations, each of them the least its body consumes
(Inst.iter8), and then what follows it. The loop instruction itself is also reached after each iteration, so its own
need counts only what follows, and the matcher adds the iterations it has still to make.

A character is counted as one byte, a literal run as its bytes and a single character loop as its minimum, so the
figure can only be too small. The body of a lookaround ends at its own last instruction and the instruction that opens
one goes straight to what follows it, so a body is counted by itself. An instruction that matches right to left, which
is the body of a lookbehind, counts nothing.

The needs are worked out twice, in bytes of UTF-8 and in UTF-16 code units, and the two needs of the program are
returned.
"""
function set_needs!(insts::Vector{Inst})
    need16, _ = needs_in!(insts, false)
    need8, _ = needs_in!(insts, true)
    return need8, need16
end

function needs_in!(insts::Vector{Inst}, utf8set::Bool)
    need = fill(NO_MATCH, length(insts))
    at(k) = need[k+1]
    passes = 0
    changed = true
    # The needs only fall, and nearly every way goes forward, so going through the instructions from the last to the
    # first settles all but the loops in one pass.
    while changed
        changed = false
        passes += 1
        for pc in length(insts)-1:-1:0
            i = insts[pc+1]
            n = NO_MATCH
            after = pc + 1
            o = i.op
            if o == OP_MATCH || o == OP_LOOK_OK || o == OP_LOOK_FAIL
                n = 0
            elseif o == OP_FAIL
            elseif o == OP_CHAR || o == OP_SET
                n = min(n, at(after) + 1)
            elseif o == OP_LIT
                n = min(n, at(after) + (utf8set ? length(i.lit8) : length(i.lit16)))
            elseif o == OP_REP || o == OP_REP_LAZY
                n = min(n, at(after) + i.min)
            elseif o == OP_JMP
                # The one way that goes back is the jump at the end of the body of a loop, to the instruction at its
                # head, which this pass has not reached. The need of that instruction is the need of what follows the
                # loop, since its other way, through the body, comes back to it and cannot need less. So the jump takes
                # what follows the loop, which this pass has settled. Taking the need of the head would settle one loop
                # of a nest for each pass: a thousand passes for loops a thousand deep.
                head = insts[i.x+1]
                if i.x < pc && head.op == OP_LOOP
                    n = min(n, at(head.x))
                elseif i.x < pc && head.op == OP_SPLIT
                    n = min(n, at(head.x), at(head.y))
                else
                    n = min(n, at(i.x))
                end
            elseif o == OP_LOOK
                n = min(n, at(i.x))
            elseif o == OP_SPLIT
                n = min(n, at(i.x), at(i.y))
            elseif o == OP_LOOP
                n = min(n, at(after), at(i.x))
            elseif o == OP_LOOP_INIT
                loop = insts[pc+2]
                n = min(n, at(after) + times_need(loop.min, utf8set ? loop.iter8 : loop.iter16))
            else
                n = min(n, at(after))
            end
            v = min(n, NO_MATCH)
            if v < need[pc+1]
                need[pc+1] = v
                changed = true
            end
        end
    end
    for (k, i) in enumerate(insts)
        if i.op == OP_LOOP
            if utf8set
                i.need8 = need[k]
            else
                i.need16 = need[k]
            end
        end
    end
    return need[1], passes
end

"""
The quick of every instruction. Every figure is a set that can only be too large: an assertion is taken to hold, a
backreference and an instruction that matches right to left (the body of a lookbehind) to allow anything. A positive
lookahead needs both its body and what follows it to go on from the same position, so it allows what both allow.
"""
set_quick(insts::Vector{Inst}) = quicks(insts)[1]

"set_quick, and also the number of passes over the instructions it made, the last of which changed nothing."
function quicks(insts::Vector{Inst})
    q = fill(QUICK_NONE, length(insts))
    at(k) = q[k+1]
    passes = 0
    changed = true
    # The sets only grow, and nearly every way goes forward, so going through the instructions from the last to the
    # first settles all but the loops in one pass.
    while changed
        changed = false
        passes += 1
        for pc in length(insts)-1:-1:0
            i = insts[pc+1]
            n = QUICK_NONE
            o = i.op
            if o == OP_MATCH || o == OP_LOOK_OK || o == OP_LOOK_FAIL
                n = QUICK_ALL
            elseif o == OP_FAIL
            elseif o == OP_CHAR
                n = add_rune(n, i.r)
            elseif o == OP_SET
                n = add_set(n, i.set)
            elseif o == OP_LIT
                n = add_rune(n, Int(i.lit8[1]))
            elseif o == OP_REP || o == OP_REP_LAZY
                n = i.set !== nothing ? add_set(n, i.set) : add_rune(n, i.r)
                i.min == 0 && (n = quick_union(n, at(pc + 1)))
            elseif o == OP_JMP
                # The jump at the end of the body of a loop goes back to the head of the loop, which this pass has not
                # reached. The head allows what follows the loop, which this pass has settled, and what the body starts
                # with. So the jump takes what follows the loop too, and the first pass settles the head of every loop,
                # the second every instruction, and the third finds nothing to change, however deep the loops nest.
                n = at(i.x)
                head = insts[i.x+1]
                if i.x < pc && head.op == OP_LOOP
                    n = quick_union(n, at(head.x))
                elseif i.x < pc && head.op == OP_SPLIT
                    n = quick_union(quick_union(n, at(head.x)), at(head.y))
                end
            elseif o == OP_SPLIT
                n = quick_union(at(i.x), at(i.y))
            elseif o == OP_LOOP
                n = quick_union(at(pc + 1), at(i.x))
            elseif o == OP_EOL
                n = Quick(0, 0, false, false, at(pc + 1).end_)
            elseif o == OP_LOOK
                n = at(i.x)
                if !i.flag
                    b = at(pc + 1)
                    n = Quick(n.ascii0 & b.ascii0, n.ascii1 & b.ascii1, n.other && b.other, n.mid && b.mid,
                        n.end_ && b.end_)
                end
            elseif o in (OP_CHAR_BACK, OP_SET_BACK, OP_BACKREF, OP_BACKREF_BACK, OP_BACKREF_FOLD, OP_BACKREF_FOLD_BACK,
                OP_BACKREF_UNITS, OP_BACKREF_UNITS_BACK)
                n = QUICK_ALL
            else
                n = at(pc + 1)
            end
            if n != q[pc+1]
                q[pc+1] = n
                changed = true
            end
        end
    end
    return q, passes
end

"""
Gives each greedy single-character loop the ASCII bytes what follows it can start with, when there are one to three
and nothing else can follow: the vectorised give-back of the .NET reference engine.
"""
function set_back!(insts::Vector{Inst}, q::Vector{Quick})
    for pc in 0:length(insts)-1
        (insts[pc+1].op != OP_REP || pc + 1 >= length(q)) && continue
        next = q[pc+2]
        (next.other || next.mid) && continue
        bytes = UInt8[]
        for c in 0x00:0x7f
            word = c < 64 ? next.ascii0 : next.ascii1
            (word >> (c & 63)) & 1 != 0 && push!(bytes, c)
        end
        1 <= length(bytes) <= 3 && (insts[pc+1].back = bytes)
    end
end

"""
Whether a code point can be matched by comparing its UTF-8 bytes. A surrogate has no encoding, and U+FFFD is also
what a malformed byte of the text decodes to.
"""
literal_rune(r::Int) = 0 <= r <= 0x10FFFF && !(0xD800 <= r <= 0xDFFF) && r != RUNE_ERROR

"Whether n can match without consuming anything. It errs towards true."
function nullable(n::Node)
    k = n.kind
    (k == N_CHAR || k == N_SET) && return false
    k == N_CAT && return all(nullable, n.subs)
    k == N_ALT && return any(nullable, n.subs)
    k == N_GROUP && return nullable(n.subs[1])
    k == N_REPEAT && return n.min == 0 || nullable(n.subs[1])
    return true
end

"Whether every way through n begins with ^."
function starts_at_bol(n::Node)
    k = n.kind
    k == N_BOL && return true
    (k == N_CAT || k == N_GROUP) && return starts_at_bol(n.subs[1])
    k == N_ALT && return all(starts_at_bol, n.subs)
    k == N_REPEAT && return n.min >= 1 && starts_at_bol(n.subs[1])
    return false
end

"""
Appends, as inclusive pairs, the code points a match of n can start with. It returns whether n can match the empty
string, and whether the set is known at all. Assertions are treated as matching the empty string, which can only make
the set larger than it need be.
"""
function first_chars!(pairs::Vector{Int}, n::Node)
    k = n.kind
    if k == N_CHAR
        push!(pairs, n.r, n.r)
        return false, true
    elseif k == N_SET
        append!(pairs, n.set.ranges)
        return false, true
    elseif k == N_CAT
        for sub in n.subs
            e, ok = first_chars!(pairs, sub)
            ok || return false, false
            e || return false, true
        end
        return true, true
    elseif k == N_ALT
        anyempty = false
        for sub in n.subs
            e, ok = first_chars!(pairs, sub)
            ok || return false, false
            anyempty = anyempty || e
        end
        return anyempty, true
    elseif k == N_GROUP
        return first_chars!(pairs, n.subs[1])
    elseif k == N_REPEAT
        n.max == 0 && return true, true
        e, ok = first_chars!(pairs, n.subs[1])
        ok || return false, false
        return e || n.min == 0, true
    elseif k == N_BACKREF
        return false, false
    end
    return true, true
end
