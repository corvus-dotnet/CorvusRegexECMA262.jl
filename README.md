# CorvusRegexEcma262.jl

Regular expressions with the grammar and the answers of ECMA-262, the `RegExp` of JavaScript, for Julia 1.10 and later.

- Every flag: `d`, `g`, `i`, `m`, `s`, `u`, `v` and `y`, with the grammar of each. Without `u` or `v` a pattern is
  read by the Annex B grammar and matched by UTF-16 code unit, as ECMA-262 matches it; with them, by code point. The
  `v` flag has nested classes, the difference and the intersection of classes, strings in a class and the seven
  properties of strings.
- ECMAScript 2025: lookbehind, named groups (and a name shared between alternatives), modifier groups such as
  `(?i:...)`, and every Unicode property ECMA-262 lists, from tables of Unicode 17 the package carries, so a pattern
  answers the same whatever Julia runs it.
- Text as UTF-8 (a `String`, a `SubString`, a vector of bytes, or a `Utf8Text`, which is checked once) or as UTF-16 (a
  vector of `UInt16`, lone surrogates and all). Nothing is transcoded. Text that is not UTF-8 is refused, never read as
  U+FFFD. One matcher serves both encodings: Julia compiles it for each.
- Base's verbs: `occursin`, `match`, `eachmatch`, `findfirst`, `findnext`, `findall`, `count`, `replace` (with every
  `$` form of `GetSubstitution`) and `split`, with ECMA-262's answers, and `ecmasplit` for String.prototype.split's
  answer, which puts the groups between the pieces. A match is an `EcmaMatch`, read as a `RegexMatch` is. The global
  search moves on as `matchAll` does. A match into a `Captures` allocates nothing once the working memory has grown.
- A pattern without a backreference is matched in time proportional to its size times the text. A pattern can be given
  a match timeout, as a `Regex` of .NET can, which bounds the time and the backtracking memory of every match. With a
  timeout and the package's limits of pattern size, neither a pattern nor a text from outside can make a program hang.
  `set_default_match_timeout!` gives every pattern one.
- The search layer of the crate: literals found by their rarest bytes, the windows of an alternation, the search after
  loops, the shapes answered without the matcher, and automata over ASCII for where a match starts and ends
  (`docs/port-checklist.md`). A global search through `eachmatch!` into a `Captures` allocates nothing.
- The matcher keeps its choices on a stack of its own; reading a deeply nested pattern recurses on the task's stack.
  The package needs 2 MB of it at most (`tools/stackprobe`), and Julia gives a task 4 MB; on a smaller stack a deep
  pattern throws a `StackOverflowError`.

**Compliance.** Over the [ECMA-262 test data](https://github.com/corvus-dotnet/ecma262-regex-test-data) (what V8 says
about its patterns and texts, test262's patterns and `exec` calls, the global search, `replace` and `split` among them,
and texts of bytes that are not UTF-8, which it refuses), the package gives every answer right and none wrong, refuses
no valid pattern, accepts no invalid one and reaches no limit, over UTF-8 and over UTF-16. CI runs the whole data on
every change.

It is a port of the Rust crate [corvus-regex-ecma262](https://github.com/corvus-dotnet/corvus-regex-ecma262-rs), and it
follows the design of the .NET engine [Corvus.Regex.Ecma262](https://github.com/corvus-dotnet/Corvus.Regex.Ecma262).

```julia
using CorvusRegexEcma262

re = ecma"(?<year>\d{4})-(?<month>\d{2})"u
occursin(re, "on 2026-10-25")                          # true
replace("2026-10-25", re => "\$<month>/\$<year>")      # "10/2026-25"

m = match(re, "on 2026-10-25")
m[:month], m.offset                                    # ("10", 4)

c = Captures(re)                                       # matches into it allocate nothing
text = Utf8Text("on 2026-10-25")                       # checked once
match!(c, text) && capture_range(c, 2)                 # 9:10

findall(ecma"\p{Lu}"u, transcode(UInt16, "Ab Cd"))     # [1:1, 4:4], in UTF-16 code units
```

Errors are exceptions: `InvalidPatternError`, `FlagsError` and `TooLargeError` from a pattern, `EncodingError` from
text that is not UTF-8, and `MatchTimeoutError` or `MatchMemoryError` from a match that reaches its limit.

## Status

Not yet released. The parser, the compiler, the matcher and the crate's search layer (where a match can start, and the
automata, `docs/port-checklist.md`) are in, and the whole test data passes. The harness of the central benchmark site
and the first release, 0.1.0, come next.

## Installing

Once 0.1.0 is registered:

```julia
using Pkg
Pkg.add("CorvusRegexEcma262")
```

The package has no dependency.

## Benchmarks

The [central benchmark site](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/) runs this repository's harness
image, `ghcr.io/corvus-dotnet/corvus-regex-ecma262-jl`, each night beside the engines of every other source: this
package over UTF-8 and UTF-16, Julia's `Base.Regex` (PCRE2, which does not claim ECMA-262) and V8, over the Industry
workloads of dotnet/performance, with each ECMA-262 engine's compliance over the test data. This repository publishes
no figures of its own. `tools/benchmarks/run.sh <workloads.json> <texts> <out.json>` runs the same harness anywhere (see
the script for what it needs).

Each figure is a Julia process of its own. The package runs a small workload while it is precompiled
(`src/precompile.jl`), so that the code a program's first pattern and match run is compiled already; a figure's process
starts in about two seconds rather than nine.

## Building and testing

```
julia --project=. -e 'using Pkg; Pkg.test()'
julia --project=. -t 4 tools/dataset/run.jl <ecma262-regex-test-data>/data wrong-cases.tsv
julia --project=. tools/stackprobe/run.jl
```

`CORVUS_REGEX_MEMO_FROM_THE_START=1` makes every match take its memory of failed places from its first step, which CI
does for a second run of both. The Unicode tables (`src/ucd/tables_gen.jl`, `src/strings_gen.jl`) are written from the
Rust crate's by `tools/unicode`, and CI checks they are current.

## Releasing

Every pull request merged into main without the `no_release` label releases the package with the next patch version
(`.github/workflows/auto-release.yml`, `tools/release`): a `v<version>` tag on a commit of the merge with the version
written into `Project.toml`, which main keeps at 0.0.0. `.github/workflows/julia-publish.yml` then asks JuliaRegistrator
to register that commit in the General registry; the [JuliaRegistrator app](https://github.com/apps/juliateam-registrator)
must be installed on the repository. A new package waits three days in General's queue. A pull request that needs a
minor or major version sets `nextVersion` in `.github/release.json`.

## License

Apache 2.0.
