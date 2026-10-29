# Writes docs/api.md, the API reference the documentation site publishes, from the package's own docstrings: each
# public name, in the sections below, with every docstring the package gives it (and never Base's, for the functions of
# Base it extends). Base's verbs (occursin, match, ...) are documented on the methods that implement them.
#
#     julia --project=. tools/docs/gen-api.jl           # write docs/api.md
#     julia --project=. tools/docs/gen-api.jl --check   # fail when docs/api.md is not what the docstrings make (CI)

using CorvusRegexEcma262
const M = CorvusRegexEcma262

# (shown as, module, binding)
const SECTIONS = [
    "Compiling" => [
        ("EcmaRegex", M, :EcmaRegex), ("@ecma_str", M, Symbol("@ecma_str")), ("try_compile", M, :try_compile),
        ("tryparse", Base, :tryparse), ("isvalid_pattern", M, :isvalid_pattern),
        ("set_default_match_timeout!", M, Symbol("set_default_match_timeout!")),
        ("default_match_timeout", M, :default_match_timeout),
    ],
    "Matching" => [
        ("occursin", M, :occursin_impl), ("match", M, :match_impl), ("findfirst, findnext", M, :findnext_impl),
        ("eachmatch", M, :eachmatch_impl), ("findall", M, :findall_impl), ("count", M, :count_impl),
        ("replace", Base, :replace), ("split", Base, :split), ("ecmasplit", M, :ecmasplit),
    ],
    "Matches and texts" => [
        ("EcmaMatch", M, :EcmaMatch), ("Utf8Text", M, :Utf8Text), ("Captures", M, :Captures), ("match!", M, Symbol("match!")),
        ("eachmatch!", M, Symbol("eachmatch!")), ("capture_range", M, :capture_range),
    ],
    "Errors" => [
        ("InvalidPatternError", M, :InvalidPatternError), ("FlagsError", M, :FlagsError), ("TooLargeError", M, :TooLargeError),
        ("EncodingError", M, :EncodingError), ("MatchTimeoutError", M, :MatchTimeoutError),
        ("MatchMemoryError", M, :MatchMemoryError),
    ],
]

function docstrings(mod, name)
    meta = Base.Docs.meta(M)
    b = Base.Docs.Binding(mod, name)
    haskey(meta, b) || error("$(mod).$(name) has no docstring in CorvusRegexEcma262")
    docs = collect(meta[b].docs)
    sort!(docs; by=p -> string(first(p)))
    return [fence(join(string.(last(p).text))) for p in docs]
end

# A docstring's indented lines (its signatures, by Julia's convention) as a fenced block of Julia, so that they read as
# code on any Markdown page; blank lines at the ends are dropped.
function fence(text)
    out = String[]
    code = String[]
    flush() = (isempty(code) || (push!(out, "```julia"); append!(out, code); push!(out, "```"); empty!(code)))
    for line in split(strip(text, '\n'), '\n')
        if startswith(line, "    ")
            push!(code, line[5:end])
        else
            flush()
            push!(out, line)
        end
    end
    flush()
    return join(out, "\n")
end

function page()
    io = IOBuffer()
    println(io, "# API reference\n")
    println(io, "The public names of `CorvusRegexEcma262`, generated from the package's docstrings by `tools/docs/gen-api.jl`.")
    println(io, "[Getting started](getting-started.md) shows them at work.\n")
    for (section, items) in SECTIONS
        println(io, "## ", section, "\n")
        for (shown, mod, name) in items
            println(io, "### ", shown, "\n")
            for d in docstrings(mod, name)
                println(io, d, "\n")
            end
        end
    end
    return rstrip(String(take!(io))) * "\n"
end

const OUT = joinpath(@__DIR__, "..", "..", "docs", "api.md")
text = page()
if "--check" in ARGS
    if !isfile(OUT) || read(OUT, String) != text
        println(stderr, "docs/api.md is not what the docstrings make: run julia --project=. tools/docs/gen-api.jl")
        exit(1)
    end
    println("docs/api.md is current")
else
    write(OUT, text)
    println("wrote docs/api.md")
end
