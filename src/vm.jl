# The backtracking matcher (vm.rs): its working memory, its limits and the memory of failed places. The matcher itself
# is in matcher.jl, one set of methods compiled for each encoding.

"""
    MatchTimeoutError(limit)

A match ran for longer than its limit, in seconds. It is not an answer.
"""
struct MatchTimeoutError <: Exception
    limit::Float64
end

Base.showerror(io::IO, e::MatchTimeoutError) = print(io, "the match ran for longer than its limit of $(e.limit) s")

"""
    MatchMemoryError()

A match needed more backtracking memory than its limit: its stack reached MAX_STACK entries. It is not an answer.
"""
struct MatchMemoryError <: Exception end

Base.showerror(io::IO, ::MatchMemoryError) = print(io, "the match needed more backtracking memory than its limit")

# The number of steps the matcher takes between two looks at the clock and at the depth of its stack. A step is one
# instruction, and eight characters of a single character loop or of a backreference. A step takes a few nanoseconds,
# so the clock is read every ten to twenty microseconds, a match that ends before its first check never reads it, and a
# match goes past its limit by that much at most.
const CHECK_EVERY = 1 << 12

"""
The number of entries the backtracking stack of a match with a limit may hold. A match that needs more is abandoned. A
pattern that keeps a choice for every character of its text needs one entry or a few for each, so this is room for a
text of some hundred thousand characters, and a pattern that pushes without consuming, such as (?:a?){2147483647},
reaches it in a few milliseconds. It is looked at with the clock, so the stack can go past it by CHECK_EVERY entries.
"""
const MAX_STACK = 1 << 20

# Why a match was abandoned.
const STOP_NONE = 0x00
const STOP_TIME = 0x01
const STOP_MEMORY = 0x02

# The kinds of entry on the backtracking stack. A choice entry says where to resume. An undo entry restores a value that
# was overwritten after the entries below it were pushed.

# Resumes at pc with the position pos.
const E_CHOICE = 0x00
# Belongs to a greedy single character loop that stopped at pos. Resuming gives back one character, down to the
# position a.
const E_REP = 0x01
# Belongs to a lazy single character loop that has taken a characters and stands at pos. Resuming takes one more.
const E_REP_LAZY = 0x02
# E_LOOK marks the start of a positive lookaround and E_LOOK_NEG of a negative one. Both hold the position to restore,
# and E_LOOK_NEG the instruction to continue at when its body has failed.
const E_LOOK = 0x03
const E_LOOK_NEG = 0x04
# Lies under the choices of a memo point. When it is reached, every way from the point has failed, and the bit pos of
# the memory is set (see memo in State).
const E_MARK = 0x05
# Restores the entry position of group pc to pos.
const E_TMP = 0x06
# Restores the start and end of group pc to pos and a.
const E_CAP = 0x07
# Restores the count and the iteration start of loop pc to pos and a.
const E_COUNTER = 0x08

struct Entry
    kind::UInt8
    pc::Int32
    pos::Int
    a::Int
end

Entry(kind::UInt8, pc::Integer, pos::Integer) = Entry(kind, Int32(pc), pos, 0)

# The value of a group that has not taken part, and of the start of an iteration that has not started.
const NONE = -1

"""
The working memory of one match. A match takes one from a pool and gives it back, so a match allocates only while the
stack is still growing to the depth the pattern and the text need. Groups, temporaries and counters are indexed from
1 here: slot k of the program is caps[2k+1] and caps[2k+2].
"""
mutable struct State
    stack::Vector{Entry}
    # The start and end of each tracked group, or NONE, and the position at which each was entered.
    caps::Vector{Int}
    tmp::Vector{Int}
    # For each loop, the number of iterations started and the position at which the last one started.
    counts::Vector{Int}
    # Where the match that was found ends.
    end_::Int
    # The time the match may take in nanoseconds, or 0 for no limit. The clock starts at the first check, so deadline
    # is set then.
    limit::Int
    deadline::UInt64
    # The number of steps left before the next check, and why the match was abandoned.
    steps::Int
    stop::UInt8
    # The memory of the places where a way has failed: one bit for each memo point of the program, each position of
    # the text and each state of the loops around the point (see MemoPoint). A bit is set when every way from the place
    # has failed, and a way that comes to a place whose bit is set fails at once. So no place is gone through twice,
    # and a pattern of repetitions inside repetitions takes time proportional to its size times the text and not time
    # that doubles with each character.
    #
    # The memory costs its size to clear, and a mark on the stack for each place gone through, so a match starts
    # without it. It takes it at the check by which it has made as many steps as the memory has words and
    # MEMO_STEPS_PER_POSITION more for each position of the text, which a match that goes through its text once or a
    # few times never makes. A place whose way failed before then is not remembered, which loses time and nothing else.
    # memo_on says the memory is in use, memo_off that it never will be (the program has no memo points, or the memory
    # would be larger than MAX_MEMO_WORDS), and width is the number of positions of the text.
    memo::Vector{UInt64}
    memo_on::Bool
    memo_off::Bool
    width::Int
    checks::Int
    points::Int
    # The stack has grown past MAX_RETAINED_STACK in this match (seen at a check), so it is not kept.
    big::Bool
end

State() = State(Entry[], Int[], Int[], Int[], 0, 0, 0, CHECK_EVERY, STOP_NONE, UInt64[], false, false, 0, 0, 0, false)

# The largest memory of failed places, in words of 64 bits: 8 MB. A match that would need more goes without it.
const MAX_MEMO_WORDS = 1 << 20

# The number of steps for each position of the text that a match makes before it takes the memory into use.
const MEMO_STEPS_PER_POSITION = 64
# The largest memory kept between matches.
const MAX_RETAINED_MEMO = 1 << 16
# The depth of the backtracking stack beyond which a memo point is not marked. A mark is an entry of the stack, and a
# pattern that keeps no choice for a character still marks a place for each, so on a long text the marks alone would
# reach MAX_STACK. A place that is not marked is not remembered, which loses time and nothing else, and the places
# below this depth are remembered when the stack unwinds, so a later start has the room to mark the next ones.
const MAX_MARK_DEPTH = MAX_STACK ÷ 2
# The largest stack kept between matches.
const MAX_RETAINED_STACK = 1 << 16

# Makes every match take its memory of failed places before its first step, so that every pattern is run with the
# memory in use. The environment variable CORVUS_REGEX_MEMO_FROM_THE_START=1 sets it when the package is loaded, which
# CI does for a second run of the tests and of the test data.
const MEMO_FROM_THE_START = Ref(false)

# The states not in use. A task takes one for a match and gives it back.
const STATES = State[]
const STATES_LOCK = Threads.SpinLock()

function take_state()
    lock(STATES_LOCK)
    st = isempty(STATES) ? nothing : pop!(STATES)
    unlock(STATES_LOCK)
    return st === nothing ? State() : st
end

function give_state(st::State)
    lock(STATES_LOCK)
    push!(STATES, st)
    unlock(STATES_LOCK)
end

"Takes the memory of failed places into use when the match has made enough steps to pay for it."
function remember!(st::State)
    words = (((st.points * st.width) << MAX_MEMO_LOOPS) + 63) >> 6
    if words > MAX_MEMO_WORDS
        st.memo_off = true
        return
    end
    st.checks * CHECK_EVERY < words + MEMO_STEPS_PER_POSITION * st.width && !MEMO_FROM_THE_START[] && return
    resize!(st.memo, words)
    fill!(st.memo, 0)
    st.memo_on = true
    return
end

"Called every CHECK_EVERY steps. It reports whether the match may go on."
@noinline function check!(st::State, depth::Int)
    if !st.memo_on && !st.memo_off
        st.checks += 1
        remember!(st)
    end
    depth > MAX_RETAINED_STACK && (st.big = true)
    st.limit <= 0 && return true
    if depth > MAX_STACK
        st.stop = STOP_MEMORY
        return false
    end
    now = time_ns()
    if st.deadline == 0
        st.deadline = now + UInt64(st.limit)
    elseif now > st.deadline
        st.stop = STOP_TIME
        return false
    end
    return true
end

"Applies one undo entry."
@inline function undo!(st::State, e::Entry)
    k = Int(e.pc)
    if e.kind == E_TMP
        @inbounds st.tmp[k+1] = e.pos
    elseif e.kind == E_CAP
        @inbounds st.caps[2k+1], st.caps[2k+2] = e.pos, e.a
    elseif e.kind == E_COUNTER
        @inbounds st.counts[2k+1], st.counts[2k+2] = e.pos, e.a
    end
end

"Readies the state for a match of the program over a text of `len` units, with a limit in nanoseconds or 0."
function reset!(st::State, p::Program, len::Int, limit::Int)
    resize!(st.caps, 2 * p.groups)
    fill!(st.caps, NONE)
    resize!(st.tmp, p.groups)
    fill!(st.tmp, 0)
    resize!(st.counts, 2 * p.loops)
    fill!(st.counts, 0)
    st.limit, st.deadline, st.steps, st.stop = max(limit, 0), UInt64(0), CHECK_EVERY, STOP_NONE
    st.memo_on, st.memo_off, st.checks = false, isempty(p.points), 0
    st.width, st.points = len + 1, length(p.points)
    !st.memo_off && MEMO_FROM_THE_START[] && remember!(st)
    return st
end

"Gives up a stack or a memory too large to keep between matches."
function release!(st::State)
    if st.big || length(st.stack) > MAX_RETAINED_STACK
        st.stack = Entry[]
        st.big = false
    end
    if length(st.memo) > MAX_RETAINED_MEMO
        st.memo = UInt64[]
    end
end

"""
The bit of the memory for the memo point m at a position, with the state of the loops around the point: for each,
whether it would refuse an iteration that ended here as empty.
"""
@inline function memo_index(p::Program, st::State, m::Int, pos::Int)
    @inbounds pt = p.points[m]
    idx = ((m - 1) * st.width + pos) << MAX_MEMO_LOOPS
    @inbounds for k in 1:MAX_MEMO_LOOPS
        l = pt.loops[k]
        if l >= 0 && st.counts[2l+1] > pt.mins[k] && st.counts[2l+2] == pos
            idx |= 1 << (k - 1)
        end
    end
    return idx
end

@inline memo_has(st::State, idx::Int) = @inbounds (st.memo[(idx>>6)+1] >> (idx & 63)) & 1 != 0
@inline memo_set!(st::State, idx::Int) = @inbounds st.memo[(idx>>6)+1] |= UInt64(1) << (idx & 63)

"Throws the error of a match abandoned for the reason, if it was."
function throw_stop(stop::UInt8, limit::Int)
    stop == STOP_TIME && throw(MatchTimeoutError(limit / 1e9))
    stop == STOP_MEMORY && throw(MatchMemoryError())
    return nothing
end

"""
The width of the character at the position when the instruction's character or class matches it, and 0 otherwise; r
and w are the character and its width.
"""
@inline function one_of(i::Inst, r::Int, w::Int)
    set = i.set
    if set !== nothing
        r in set || return 0
    elseif r != i.r
        return 0
    end
    return w
end
