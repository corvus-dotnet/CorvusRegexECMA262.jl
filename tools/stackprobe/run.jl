# Asks the engine about patterns built to overflow the stack: deep (groups, lookarounds, modifier groups, quantified
# groups and the classes of the v flag, each nested to the limit, one past it and far past it), wide (many groups,
# classes, alternatives, backreferences, set operations and string alternatives side by side) and long (the longest
# pattern allowed, and one past it), in every grammar, through every verb over UTF-8 and UTF-16, as the Rust crate's
# stack-probe does.
#
#   julia --project=. tools/stackprobe/run.jl [--stacks 4M,2M] [--filter text]
#
# Each probe runs in a task of its own with each of the stacks (Julia gives a task 4 MB unless it is made with another
# size). A probe is answered (compiled and matched), refused (not valid, or too large, which a caller can catch), or a
# fault: a stack overflow, or any other error. Any fault makes the exit status 1. Julia throws StackOverflowError where
# a task's stack runs out, so a fault is seen in the process rather than ending it.

using CorvusRegexECMA262
const C = CorvusRegexECMA262

struct Probe
    name::String
    flags::String
    build::Function
end

nest(open, body, close, depth) = open^depth * body * close^depth
text(n) = "a"^min(max(n, 64), 1 << 20) * "b"

function probes()
    all = Probe[]
    add(name, flags, build) = push!(all, Probe(name, flags, build))
    depths = [32, 33, 200, 1000, 1001, 5000, 200_000]
    grammars = ["", "u", "v", "i", "iv"]
    # Deep: each kind of group nested.
    groups = [("group", "(", ")"), ("non-capturing", "(?:", ")"), ("lookahead", "(?=", ")"),
        ("negative lookahead", "(?!", ")"), ("lookbehind", "(?<=", ")"), ("negative lookbehind", "(?<!", ")"),
        ("modifier i", "(?i:", ")"), ("modifier -i", "(?-i:", ")"), ("star", "(?:", ")*"), ("counted", "(?:", "){2}"),
        ("lazy plus", "(?:", ")+?"), ("alternative", "(?:b|", ")")]
    for (kind, open, close) in groups, depth in depths, flags in grammars
        add("deep $kind x$depth /$flags", flags, () -> (nest(open, "a", close, depth), text(depth)))
    end
    for depth in depths, flags in grammars
        add("deep named x$depth /$flags", flags,
            () -> (join("(?<g$i>" for i in 0:depth-1) * "a" * ")"^depth, text(depth)))
        add("deep backreference x$depth /$flags", flags, () -> (nest("(", "a", ")\\1", depth), text(depth)))
    end
    # Deep: the classes of the v flag nested, asked of every grammar (the others refuse them as not valid).
    classes = [("class", "[", "a", "]"), ("negated class", "[^", "a", "]"), ("difference", "[a--", "[b]", "]"),
        ("intersection", "[a&&", "[a]", "]"), ("string alternatives", "[\\q{ab|c}", "a", "]"),
        ("class in a group", "(?:[", "a", "])")]
    for (kind, open, body, close) in classes, depth in depths, flags in grammars
        add("deep $kind x$depth /$flags", flags, () -> (nest(open, body, close, depth), text(depth)))
    end
    for depth in depths
        add("deep [ unclosed x$depth /v", "v", () -> ("["^depth, text(64)))
        add("deep ( unclosed x$depth /v", "v", () -> ("("^depth, text(64)))
    end
    # Wide: many of one thing side by side.
    wide = [("alternatives", w -> "a|"^w * "b"), ("empty groups", w -> "()"^w), ("groups", w -> "(a)"^w),
        ("named groups", w -> join("(?<g$i>a)" for i in 0:w-1)), ("classes", w -> "[a]"^w),
        ("lookaheads", w -> "(?=a)"^w * "a"), ("backreferences", w -> "(a)" * "\\1"^w), ("optional", w -> "a?"^w),
        ("optional groups", w -> "(?:a?)"^w), ("ranges in a class", w -> "[" * "a-b"^w * "]"),
        ("properties", w -> "\\p{L}"^w), ("stars", w -> "a*"^w), ("alternatives in a star", w -> "(?:" * "a|"^w * "b)*"),
        ("differences", w -> "[a" * "--b"^w * "]"), ("intersections", w -> "[a" * "&&a"^w * "]"),
        ("string alternatives", w -> "[\\q{" * "a|"^w * "b}]")]
    for width in [1000, 100_000, 300_000], (kind, pattern) in wide, flags in grammars
        add("wide $kind x$width /$flags", flags, () -> (pattern(width), text(width)))
    end
    # Long: the longest pattern allowed, and one past it.
    for len in [C.MAX_PATTERN_LENGTH, C.MAX_PATTERN_LENGTH + 1], flags in grammars
        add("long literal x$len /$flags", flags, () -> ("a"^len, text(len)))
    end
    return all
end

"Everything the engine is asked about one probe; the answer is a line."
function ask(p::Probe)
    pattern, s = p.build()
    valid = C.isvalid_pattern(pattern, p.flags)
    re = try
        EcmaRegex(pattern, p.flags; match_timeout=5.0)
    catch e
        if e isa C.TooLargeError
            return valid ? "FAULT isvalid_pattern accepted a pattern too large to compile" : "refused too large"
        elseif e isa C.InvalidPatternError
            return valid ? "FAULT isvalid_pattern accepted a pattern the constructor refused: $(sprint(showerror, e))" :
                   "refused not valid"
        end
        rethrow()
    end
    valid || return "FAULT isvalid_pattern refused a pattern the constructor accepted"
    u = transcode(UInt16, s)
    answers = String[]
    function add(f)
        try
            push!(answers, string(f()))
        catch e
            e isa StackOverflowError && rethrow()
            push!(answers, sprint(showerror, e))
        end
    end
    add(() -> occursin(re, s))
    add(() -> occursin(re, u))
    add(() -> findfirst(re, s))
    add(() -> match(re, s) === nothing ? nothing : match(re, s).offsets)
    add(() -> match(re, u) === nothing ? nothing : match(re, u).offsets)
    add(() -> length(findall(re, s)))
    add(() -> length(findall(re, u)))
    add(() -> length(collect(eachmatch(re, s))))
    c = Captures(re)
    add(() -> match!(c, s))
    add(() -> length(replace(s, re => "\$1x")))
    add(() -> length(replace(u, re => UInt16['x'])))
    add(() -> length(ecmasplit(s, re)))
    add(() -> length(ecmasplit(u, re)))
    return "answered " * join(answers, " ")
end

function size_of(s::AbstractString)
    n = parse(Int, s[1:end-1])
    unit = s[end]
    unit == 'K' && return n << 10
    unit == 'M' && return n << 20
    unit == 'G' && return n << 30
    error("a stack size such as 256K or 8M")
end

"The answer to a probe on a task with the stack, or the fault."
function on_stack(p::Probe, stack::Int)
    t = Task(() -> try
            ask(p)
        catch e
            e isa StackOverflowError ? "FAULT stack overflow" : "FAULT $(sprint(showerror, e))"
        end, stack)
    schedule(t)
    return fetch(t)
end

function main(args)
    stacks = ["4M", "2M"]
    filter = ""
    k = 1
    while k <= length(args)
        args[k] == "--stacks" && (stacks = split(args[k+1], ","))
        args[k] == "--filter" && (filter = args[k+1])
        k += 2
    end
    all = [p for p in probes() if occursin(filter, p.name)]
    started = time()
    answered, refused = 0, 0
    faults = String[]
    for p in all, s in stacks
        r = on_stack(p, size_of(s))
        if startswith(r, "answered")
            answered += 1
        elseif startswith(r, "refused")
            refused += 1
        else
            push!(faults, "$(p.name) on $s: $r")
        end
    end
    foreach(println, sort(faults))
    println("$(length(all)) probes on $(length(stacks)) stacks: $answered answered, $refused refused, ",
        "$(length(faults)) faults, in $(round(Int, time() - started)) s")
    isempty(faults) || exit(1)
end

main(ARGS)
