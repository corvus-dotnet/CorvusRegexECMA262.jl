# The Industry benchmark: each workload counted by each engine, as the V8 harness of the .NET reference engine
# (tools/benchmarks/v8/industry.mjs) counts it, in nanoseconds per count. A port of the Rust crate's
# tools/src/bin/industry.rs (by way of the Go engine's tools/benchmarks/industry), with the same protocol.
#
#   julia --project=. tools/benchmarks/industry.jl <workloads.json> [--engines corvus-utf8,corvus-utf16,pcre2,v8]
#         [--v8 <industry.mjs>] [--rounds 3] [--seconds 0.7] [--passes 7] [--spread 0.05]
#         [--filter <substring of the id>] [--ids <file>] [--out <results.json>]
#
# The protocol is interleaved, so that what changes on the host over a run (its clock, its heat, its other work) falls
# on every engine alike: the workloads are the outer loop, each workload's rounds next and the engines innermost, their
# order turned by one each round. Each figure is a child process of its own (this script, or Node for V8), so that one
# engine's caches, heap and collector do not reach another's figures; it warms for two fifths of its seconds, then
# times passes passes of as many counts as fit the rest and reports their median. Julia compiles what a figure runs on
# its first count, which is made before the warming. A workload's figure for an engine is the median of its rounds, with
# the fastest and the slowest round as its spread. Where the spread, (slowest - fastest) / median, is over --spread, the
# figure is listed in the run's facts and on stderr. A figure that does not finish in 30 s is stopped and recorded as
# giving no result within 30 s, and is not run in the workload's later rounds. A count is the global search of
# ECMA-262: after an empty match the search goes on one character later.
#
# The engines: this library over UTF-8 (a Utf8Text, checked once before the timing) and over UTF-16 (a vector of
# UInt16), with the workload's flags and u, counted by `count` (corvus-utf8, corvus-utf16); pcre2, Julia's Base.Regex
# (PCRE2 with its JIT), which is given the pattern as it is and the flags i, m and s, counted by `count`, and whose
# figure is an error where the pattern does not compile; and V8 (--v8, the harness run by node), with gu added.
#
# An engine may name another checkout of this repository as engine@<directory> (corvus-utf8@/tmp/base), which runs that
# engine's figures with that checkout's package, so that two versions of the library are timed side by side in one
# interleaved run.
#
# The texts are those of the reference run, in CORVUS_REGEX_TEXTS (or ~/.local/share/corvus-regex-benchmarks) and
# fetched from dotnet/performance when missing. The run unzips each once into a directory of its own
# (CORVUS_REGEX_PLAIN), which the children read.

using CorvusRegexECMA262
using Printf

const SOURCE = "https://raw.githubusercontent.com/dotnet/performance/main/src/benchmarks/micro/libraries/" *
               "System.Text.RegularExpressions/TestData/"
const DEFAULT_ENGINES = ["corvus-utf8", "corvus-utf16", "pcre2"]
# A figure stopped at the limit, which the page shows as giving no result within 30 s.
const STOPPED = "{\"error\":\"did not produce a result within 30 s\",\"limit\":30}"
# What the counts are summed into, so that no count is taken away as dead code.
const SINK = Ref(0)

fail(msg) = (println(stderr, "industry: ", msg); exit(2))

# A small JSON reader, for the workloads and the children's lines.
mutable struct JReader
    s::String
    i::Int
end

function jvalue(r::JReader)
    jspace(r)
    c = r.s[r.i]
    if c == '{'
        r.i += 1
        d = Dict{String,Any}()
        jspace(r)
        r.s[r.i] == '}' && (r.i += 1; return d)
        while true
            jspace(r)
            k = jstring(r)
            jspace(r)
            r.s[r.i] == ':' || error("expected :")
            r.i += 1
            d[k] = jvalue(r)
            jspace(r)
            r.s[r.i] == ',' && (r.i += 1; continue)
            r.s[r.i] == '}' || error("expected }")
            r.i += 1
            return d
        end
    elseif c == '['
        r.i += 1
        a = Any[]
        jspace(r)
        r.s[r.i] == ']' && (r.i += 1; return a)
        while true
            push!(a, jvalue(r))
            jspace(r)
            r.s[r.i] == ',' && (r.i += 1; continue)
            r.s[r.i] == ']' || error("expected ]")
            r.i += 1
            return a
        end
    elseif c == '"'
        return jstring(r)
    elseif startswith(SubString(r.s, r.i), "true")
        r.i += 4
        return true
    elseif startswith(SubString(r.s, r.i), "false")
        r.i += 5
        return false
    elseif startswith(SubString(r.s, r.i), "null")
        r.i += 4
        return nothing
    end
    start = r.i
    while r.i <= ncodeunits(r.s) && r.s[r.i] in "+-0123456789.eE"
        r.i += 1
    end
    return parse(Float64, r.s[start:r.i-1])
end

jspace(r::JReader) = while r.i <= ncodeunits(r.s) && r.s[r.i] in " \t\r\n"
    r.i += 1
end

function jstring(r::JReader)
    r.i += 1
    io = IOBuffer()
    pending = 0
    while true
        c = r.s[r.i]
        if c == '"'
            r.i += 1
            return String(take!(io))
        elseif c == '\\'
            e = r.s[r.i+1]
            r.i += 2
            if e == 'u'
                u = parse(Int, r.s[r.i:r.i+3]; base=16)
                r.i += 4
                if 0xD800 <= u <= 0xDBFF && r.s[r.i] == '\\' && r.s[r.i+1] == 'u'
                    low = parse(Int, r.s[r.i+2:r.i+5]; base=16)
                    if 0xDC00 <= low <= 0xDFFF
                        r.i += 6
                        u = 0x10000 + (u - 0xD800) << 10 + (low - 0xDC00)
                    end
                end
                print(io, 0xD800 <= u <= 0xDFFF ? '�' : Char(u))
            else
                print(io, get(Dict('n' => '\n', 't' => '\t', 'r' => '\r', 'b' => '\b', 'f' => '\f'), e, e))
            end
        else
            print(io, c)
            r.i = nextind(r.s, r.i)
        end
    end
end

parse_json(s::AbstractString) = jvalue(JReader(String(s), 1))

json_string(s::AbstractString) = "\"" * escape_string(s, "\"") * "\""

workloads(path) = parse_json(read(path, String))

text_dir() = get(ENV, "CORVUS_REGEX_TEXTS", joinpath(homedir(), ".local", "share", "corvus-regex-benchmarks"))

"The bytes of a text: gunzipped, without a byte order mark (as unzipped in CORVUS_REGEX_PLAIN)."
function text(file::String)
    plain = get(ENV, "CORVUS_REGEX_PLAIN", "")
    if plain != ""
        p = joinpath(plain, replace(file, r"\.gz$" => ""))
        isfile(p) && return read(p)
    end
    path = joinpath(text_dir(), file)
    if !isfile(path)
        mkpath(text_dir())
        run(`curl -sSfL -o $path $(SOURCE * file)`)
    end
    b = read(pipeline(`gzip -dc $path`))
    length(b) >= 3 && b[1:3] == [0xEF, 0xBB, 0xBF] && (b = b[4:end])
    return b
end

"The workload's flags with u added, unless it has u or v."
flags_u(flags::String) = occursin(r"[uv]", flags) ? flags : flags * "u"

"One figure's times, in nanoseconds per count, its count and the counts timed."
struct Figures
    median::Float64
    min::Float64
    max::Float64
    count::Int
    reps::Int
end

"Times a count: it warms, then times the passes."
function measure(seconds::Float64, passes::Int, count::F) where {F}
    expected = count()
    warm_end = time_ns() + round(UInt64, seconds * 0.4e9)
    reps = 0
    while time_ns() < warm_end
        count() == expected || error("the count changed")
        reps += 1
    end
    per_pass = max(1, round(Int, reps * 0.6 / passes))
    times = zeros(passes)
    for p in 1:passes
        t0 = time_ns()
        s = 0
        for _ in 1:per_pass
            s += count()
        end
        times[p] = (time_ns() - t0) / per_pass
        SINK[] += s
    end
    sort!(times)
    return Figures(times[passes÷2+1], times[1], times[end], expected, per_pass * passes)
end

"Runs one workload on one engine in this process and prints its figures as one line of JSON."
function one(path::String, index::Int, engine::String, seconds::Float64, passes::Int)
    w = workloads(path)[index+1]
    b = text(w["file"])
    f = try
        if engine == "corvus-utf8"
            t = Utf8Text(b)
            re = EcmaRegex(w["pattern"], flags_u(w["flags"]))
            measure(seconds, passes, () -> count(re, t))
        elseif engine == "corvus-utf16"
            u = transcode(UInt16, String(copy(b)))
            re = EcmaRegex(w["pattern"], flags_u(w["flags"]))
            measure(seconds, passes, () -> count(re, u))
        elseif engine == "pcre2"
            s = String(copy(b))
            re = Regex(w["pattern"], filter(c -> c in "ims", w["flags"]))
            measure(seconds, passes, () -> count(re, s))
        else
            error("unknown engine $engine")
        end
    catch e
        println("{\"error\":", json_string(first(split(sprint(showerror, e), '\n'))), "}")
        return
    end
    @printf("{\"median\":%.1f,\"min\":%.1f,\"max\":%.1f,\"count\":%d,\"reps\":%d}\n", f.median, f.min, f.max, f.count, f.reps)
end

"Runs engine over workload index in a child process, and returns its line of JSON, or one with the error."
function figure(v8, path, index, engine, seconds, passes)
    cmd = if engine == "v8"
        `node $v8 --one $path $index $seconds $passes`
    elseif occursin('@', engine)
        # Another checkout of this repository, whose package and harness run the figure.
        name, checkout = split(engine, '@'; limit=2)
        script = joinpath(checkout, "tools", "benchmarks", "industry.jl")
        `$(Base.julia_cmd()) --startup-file=no --project=$checkout $script --one $path $index $name $seconds $passes`
    else
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $(@__FILE__) --one $path $index $engine $seconds $passes`
    end
    out = Pipe()
    p = run(pipeline(cmd; stdin=devnull, stdout=out, stderr=stderr); wait=false)
    close(out.in)
    # The watchdog stays until the child has ended: a child that gave its line ends by itself, and one that runs past the
    # limit is killed outright.
    stopped = Ref(false)
    timer = Timer(30) do _
        stopped[] = true
        kill(p, Base.SIGKILL)
    end
    line = readline(out)
    wait(p)
    close(timer)
    stopped[] && return STOPPED
    isempty(line) && return "{\"error\":\"the process ended without figures\"}"
    return strip(line)
end

median_of(sorted) = isodd(length(sorted)) ? sorted[length(sorted)÷2+1] :
                    (sorted[length(sorted)÷2] + sorted[length(sorted)÷2+1]) / 2

first_line(cmd) = try
    first(split(read(cmd, String), '\n'))
catch
    ""
end

function field(file, prefix)
    isfile(file) || return ""
    for l in eachline(file)
        startswith(l, prefix) && return strip(split(l, ':'; limit=2)[2])
    end
    return ""
end

"The version of the PCRE2 library Julia's Regex runs on."
function pcre2_version()
    buf = Vector{UInt8}(undef, 64)
    n = ccall((:pcre2_config_8, Base.PCRE.PCRE_LIB), Cint, (UInt32, Ptr{UInt8}), 11, buf)
    return String(buf[1:n-1])
end

"What the run is: the host, the runtime, the affinity, the load and the commit, read from the run."
function facts(seconds, passes, extra)
    load = isfile("/proc/loadavg") ? first(split(read("/proc/loadavg", String))) : ""
    commit = get(ENV, "CORVUS_COMMIT", "")
    commit == "" && (commit = first_line(`git rev-parse HEAD`))
    f = [("cpu", field("/proc/cpuinfo", "model name")), ("cores", string(Sys.CPU_THREADS)),
        ("affinity", field("/proc/self/status", "Cpus_allowed_list")), ("os", first_line(`uname -sr`)), ("load", load),
        ("julia", "Julia $(VERSION) $(Sys.KERNEL)/$(Sys.ARCH)"), ("commit", commit),
        ("date", Libc.strftime("%Y-%m-%dT%H:%M:%SZ", time())), ("seconds", seconds), ("passes", passes),
        # On a GitHub-hosted runner, what the runner says it is.
        ("runner", get(ENV, "RUNNER_NAME", "")), ("runner_os", get(ENV, "RUNNER_OS", "")),
        ("image", strip(get(ENV, "ImageOS", "") * " " * get(ENV, "ImageVersion", ""))),
        ("corvus-regex-ecma262", string(pkgversion(CorvusRegexECMA262))),
        ("pcre2", "PCRE2 $(pcre2_version()) (Julia $(VERSION))")]
    append!(f, extra)
    return "{" * join([json_string(k) * ":" * json_string(string(v)) for (k, v) in f], ",") * "}"
end

function count_of(line)
    m = try
        parse_json(line)
    catch
        return nothing
    end
    c = get(m, "count", nothing)
    return c isa Float64 ? Int(c) : nothing
end

function main(args)
    if length(args) > 0 && args[1] == "--one"
        one(args[2], parse(Int, args[3]), args[4], parse(Float64, args[5]), parse(Int, args[6]))
        return
    end
    isempty(args) && fail("usage: industry.jl <workloads.json> [--engines ...] [--v8 <industry.mjs>] [--out <file>]")
    path = args[1]
    opt = Dict(args[k] => args[k+1] for k in 2:2:length(args)-1)
    v8 = get(opt, "--v8", "")
    engines = haskey(opt, "--engines") ? split(opt["--engines"], ",") :
              (v8 != "" ? vcat(DEFAULT_ENGINES, "v8") : copy(DEFAULT_ENGINES))
    "v8" in engines && v8 == "" && fail("V8 is run by the V8 harness: give --v8 <industry.mjs>")
    rounds = parse(Int, get(opt, "--rounds", "3"))
    seconds, passes = get(opt, "--seconds", "0.7"), get(opt, "--passes", "7")
    limit = parse(Float64, get(opt, "--spread", "0.05"))
    filter_ = get(opt, "--filter", "")
    # One id a line: the ids hold spaces.
    ids = haskey(opt, "--ids") ? filter(!isempty, strip.(readlines(opt["--ids"]))) : nothing
    all = workloads(path)
    chosen = [k for (k, w) in enumerate(all) if occursin(filter_, w["id"]) && (ids === nothing || w["id"] in ids)]
    plain = get(ENV, "CORVUS_REGEX_PLAIN", "")
    plain == "" && fail("run.sh sets CORVUS_REGEX_PLAIN, the directory of the unzipped texts")
    # The texts unzipped once, for every child.
    mkpath(plain)
    for w in all
        p = joinpath(plain, replace(w["file"], r"\.gz$" => ""))
        isfile(p) || write(p, text(w["file"]))
    end
    ne = length(engines)
    times = [[Float64[] for _ in all] for _ in 1:ne]
    lines = [fill("", length(all)) for _ in 1:ne]
    names = Dict{String,String}()
    for (done, k) in enumerate(chosen)
        for round in 0:rounds-1, turn in 0:ne-1
            e = (turn + round) % ne + 1
            # A figure stopped at the limit in an earlier round is not run again.
            lines[e][k] == STOPPED && continue
            line = figure(v8, path, k - 1, engines[e], seconds, passes)
            parsed = try
                parse_json(line)
            catch
                Dict{String,Any}()
            end
            if get(parsed, "median", nothing) isa Float64
                push!(times[e][k], parsed["median"])
            else
                println(stderr, rpad(engines[e], 13), " ", rpad(all[k]["id"], 62), " ", line)
            end
            get(parsed, "engine", nothing) isa String && (names[engines[e]] = parsed["engine"])
            lines[e][k] = line
        end
        println(stderr, "workload $done of $(length(chosen)) done")
    end
    over, differ = String[], String[]
    # V8 is the oracle of the counts: an engine that counts otherwise has given a wrong answer, whatever its dialect.
    v8e = findfirst(==("v8"), engines)
    oracle = Vector{Union{Nothing,Int}}(nothing, length(all))
    for k in eachindex(all)
        if v8e !== nothing
            oracle[k] = count_of(lines[v8e][k])
        elseif get(all[k], "v8Count", nothing) isa Float64
            oracle[k] = Int(all[k]["v8Count"])
        end
    end
    results = String[]
    for (e, engine) in enumerate(engines)
        rows = String[]
        for k in chosen
            line, ts = lines[e][k], times[e][k]
            id = all[k]["id"]
            entry = if length(ts) < rounds
                # A round with no figure (an error, a limit) makes the figure an error.
                occursin("\"error\"", line) ? line : "{\"error\":\"a round gave no figure\"}"
            else
                sorted = sort(ts)
                m, lo, hi = median_of(sorted), sorted[1], sorted[end]
                spread = m > 0 ? (hi - lo) / m : 0.0
                if spread > limit
                    push!(over, @sprintf("%s %s %.1f%%", engine, id, spread * 100))
                    println(stderr, @sprintf("SPREAD %-13s %-62s %.1f%% over %.1f%%", engine, id, spread * 100, limit * 100))
                end
                count = something(count_of(line), 0)
                o = oracle[k]
                if o !== nothing && o != count && engine != "v8"
                    push!(differ, "$engine $id $count vs V8 $o")
                    println(stderr, @sprintf("COUNT  %-13s %-62s %d against V8's %d", engine, id, count, o))
                    "{\"error\":" * json_string("counted $count where V8 counts $o") * "}"
                else
                    @sprintf("{\"median\":%.1f,\"min\":%.1f,\"max\":%.1f,\"count\":%d,\"rounds\":%d,\"spread\":%.4f,\"each\":[%s]}",
                        m, lo, hi, count, length(ts), spread, join([@sprintf("%.1f", t) for t in ts], ","))
                end
            end
            push!(rows, json_string(id) * ":" * entry)
        end
        push!(results, json_string(engine) * ":{" * join(rows, ",") * "}")
    end
    extra = [("rounds", string(rounds)), ("protocol", "interleaved"), ("spread_limit", string(limit)),
        ("spread_over", join(over, "; ")), ("counts_differ", join(differ, "; ")), ("v8", get(names, "v8", ""))]
    end_ = Libc.strftime("%Y-%m-%dT%H:%M:%SZ", time())
    out = "{\"facts\":" * facts(seconds, passes, extra) * ",\"end\":" * json_string(end_) * ",\"results\":{" *
          join(results, ",") * "}}\n"
    if haskey(opt, "--out")
        write(opt["--out"], out)
    else
        print(out)
    end
end

main(copy(ARGS))
