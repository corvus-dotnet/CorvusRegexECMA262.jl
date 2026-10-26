"""
    CorvusRegexEcma262

Regular expressions with the grammar and the answers of ECMA-262, the `RegExp` of JavaScript: a port of the Rust crate
corvus-regex-ecma262.
"""
module CorvusRegexEcma262

include("ucd/UCD.jl")
using .UCD

include("charset.jl")
include("fold.jl")
include("units.jl")
include("parse.jl")

end
