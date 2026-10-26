"""
    CorvusRegexEcma262

Regular expressions with the grammar and the answers of ECMA-262, the `RegExp` of JavaScript, over UTF-8 (a `String`,
a `SubString`, or a `Utf8Text`, which is checked once) and UTF-16 (a vector of `UInt16`, lone surrogates and all).
Nothing is transcoded, and text that is not UTF-8 is refused, never read as U+FFFD.

    re = ecma"(?<year>\\d{4})-(?<month>\\d{2})"u
    occursin(re, "on 2026-10-25")                        # true
    replace("2026-10-25", re => "\\\$<month>/\\\$<year>")   # "10/2026-25"

The engine is a port of the Rust crate corvus-regex-ecma262, file for file (parse.jl is parse.rs, compile.jl is
compile.rs, and so on), held to the same ECMA-262 test data.
"""
module CorvusRegexEcma262

export EcmaRegex, @ecma_str, EcmaMatch, Utf8Text, Captures, match!, eachmatch!, capture_range, ecmasplit

include("ucd/UCD.jl")
using .UCD

include("charset.jl")
include("fold.jl")
include("units.jl")
include("parse.jl")
include("swar.jl")
include("simd.jl")
include("finder.jl")
include("literals.jl")
include("adfa.jl")
include("search.jl")
include("compile.jl")
include("automata.jl")
include("searchunits.jl")
include("vm.jl")
include("matcher.jl")
include("dfa.jl")
include("regex.jl")
include("api.jl")
include("precompile.jl")

function __init__()
    MEMO_FROM_THE_START[] = get(ENV, "CORVUS_REGEX_MEMO_FROM_THE_START", "") == "1"
end

end
