# CorvusRegexEcma262.jl: design

An outline of the package as it is: what it offers, how the engine is built and why, and how it is tested and
measured. The [getting-started page](getting-started.md) shows how to use it.

## 1. What it is

A Julia regular expression engine with ECMA-262's grammar and answers (ECMAScript 2025), worked through Base's own
verbs, over UTF-8 (`String`, `Utf8Text`) and UTF-16 (`Vector{UInt16}`). It is a port of the corvus-regex-ecma262 Rust
crate to pure Julia, with no dependencies.

**Why ECMA-262.** JSON Schema, OpenAPI and many wire formats specify their patterns as ECMAScript regular
expressions. Julia's `Regex` is PCRE2's, with its own grammar and its own meaning for `\d`, `\w`, `\s`, `.` and case
folding, so a translation to it can never be exact. An engine that reads ECMA-262 directly, held to V8's answers over a
large data set (section 6), needs no translation.

## 2. Public surface

**Names.** An `EcmaRegex` is an `AbstractPattern`, so Base's `occursin`, `match`, `eachmatch`, `findfirst`,
`findnext`, `findall`, `count`, `replace` and `split` take it, and its `EcmaMatch` reads as a `RegexMatch` does. The
`ecma"..."flags` string macro writes one into a program. `ecmasplit` is JavaScript's split, beside Base's.

**Flags.** ECMA-262's, as a string, and nothing else.

**Edition and Unicode version.** By default a pattern is read with today's grammar (`edition = :current`) and V8's
version of Unicode (`unicode_version = :default`, 17 today). Either is overridden when the pattern is compiled,
independently: `:es2020` is the grammar JSON Schema 2020-12 names, and the versions are 13, 17, 18 and `:latest`. Both
are resolved when the pattern is compiled; a pattern's `edition` and `unicode_version` fields say what it was compiled
with.

**Errors.** A pattern that does not compile throws an `InvalidPatternError` (with the message and the offset), a
`FlagsError` or a `TooLargeError`; `try_compile` returns the error in place of throwing. A match that reaches its limit
throws a `MatchTimeoutError` or a `MatchMemoryError`; text that is not UTF-8 throws an `EncodingError`.

**ECMA-262 algorithms.** `replace` takes ECMA-262's template (`$$`, `$&`, `` $` ``, `$'`, `$n`, `$nn`, `$<name>`) for
every match, with Base's `count` for fewer. `ecmasplit` follows `RegExp.prototype[Symbol.split]`.

**Input.** A `String` is UTF-8, checked before it is read and refused when it is not, never read as U+FFFD; `Utf8Text`
checks a text once. A `Vector{UInt16}` is UTF-16 code units, lone surrogates and all. Positions are Julia's string
indices, 1-based, in the text's units.

**Allocation.** A warm `occursin` and `count`, and `match!`, which writes a match's groups into a `Captures` made once,
allocate nothing: the working memory is kept up to a cap and reused.

**Limits.** No pattern and no text can hang a program or overflow the stack.

- A match timeout per pattern, or a process-wide default (`set_default_match_timeout!`), bounds every match and caps
  its backtracking memory.
- Size limits on the pattern are deterministic.
- The matcher keeps its choices on a stack of its own, and the parser's and the compiler's recursion, bounded by the
  nesting limit, fits a task's stack of 4 MB (Julia's default) and of 2 MB.

## 3. Engine

**One matcher, two encodings.** The matcher and the readers of the automata are written once over a text type, and
Julia compiles a method for each encoding, so the loop has no dynamic dispatch. Matching by UTF-16 code unit over UTF-8
places the position between the halves of a four-byte character at its third byte.

**The matcher.** A backtracking matcher over a flat program, with V8's quick check of the next character at each
choice. A memo of the places that failed, taken into use once a match has made sixty-four steps a position, makes a
pattern without backreferences linear in the text. The clock is read every 4,096 steps.

**Where a match can start.** The search layer is the Rust crate's, with Julia's tools in place of `memchr` and
`aho-corasick`. The searches read 32 bytes (16 UTF-16 units) at a time through vector compares written in LLVM's own
types with `llvmcall` (`simd.jl`), which LLVM compiles to AVX2 or SSE on x86 and NEON on ARM: one byte by libc's
`memchr`, and two to four bytes, a range of bytes, a pair of positions and the units of UTF-16 text by those compares;
any other set by SWAR over eight bytes a `UInt64` (`swar.jl`). A literal is found by its rarest byte or by two of its
rarest positions; several literals by their bytes at one position, by that pair search, or by a table; a literal at a
fixed or bounded distance opens windows of starts.

**The automata.** For a pattern that needs no backtracking: an automaton over ASCII for a test from the start, an
anchored leftmost-first automaton for where a match from a start ends, a reverse automaton for the terms before a
window's anchors, and a forward automaton for a pattern with no literal. Each is built on first use, with its states
bounded.

## 4. Precompilation and generated tables

The package runs a small workload while it is precompiled (`src/precompile.jl`), so the code a program's first pattern
and match need is compiled already, and a process starts in about two seconds rather than nine. The Unicode tables of
each version (`src/ucd/tables<major>_gen.jl`, `strings<major>_gen.jl`) and the property names of ECMAScript 2020
(`src/es2020_gen.jl`) are written from the Rust crate's by `tools/unicode`, and CI checks them against the crate. The
API reference (`docs/api.md`) is generated from the docstrings by `tools/docs/gen-api.jl`, which CI checks is current.

## 5. Targets and layout

Julia 1.10 (the LTS) and later, registered in the General registry; CI tests on Linux (x64 and arm64), macOS and
Windows, on the LTS and the latest Julia.

- `src/`: the package; `test/`: the tests, the getting-started page's examples among them.
- `tools/dataset`: the test-data runner; `tools/stackprobe`: the stack probe; `tools/unicode`: the tables' writers;
  `tools/docs`: the API reference's generator; `tools/benchmarks`: the benchmark harness.

## 6. Testing

**The ECMA-262 test data.** [`ecma262-regex-test-data`](https://github.com/corvus-dotnet/ecma262-regex-test-data)
holds V8's answers: validity under each grammar, `test` answers, the positions of `exec`, the global search, `y`,
`replace` and `split`, and every `exec` call of test262. `tools/dataset` runs all of it over UTF-8 and UTF-16, with
none wrong, refused or at a limit: on every change, again with the memo from the first step, and on Linux as the data's
own scripts write it for Unicode 13 and 18 and for ECMAScript 2020.

**Other tests.** Tests over the verbs, the editions, the searches and the automata; a test that a warm match allocates
nothing; the getting-started page's examples; and the stack probe, which asks deep, wide and long patterns through
every verb, each in a task with a stack of 4 MB and of 2 MB, none overflowing.

## 7. Benchmarks

The harness image, `ghcr.io/corvus-dotnet/corvus-regex-ecma262-jl`, runs the Industry workloads of
`dotnet/performance` over this package (UTF-8 and UTF-16), Julia's `Regex` (PCRE2) and V8, each figure a Julia process
of its own. The published figures are on
[the benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), which runs every engine's image each
night; this repository publishes none of its own.

Three rows are not like for like with an engine that is not ECMA-262's, as the price of its rules under u: `.*` (`.`
excludes CR, so the CRLF text has more matches), `Sher[a-z]+|Hol[a-z]+` under i (the search must also find the long s
and the Kelvin sign), and `[a-q][^u-z]{13}x` (a supplementary character is two units, so the distance to the `x` is
not fixed).

## 8. Differences a Julia user will meet

- The grammar is ECMA-262's, not PCRE2's: `(?i:...)` groups but no `(?i)` prefix, no possessive quantifiers, atomic
  groups, `\A`, `\z` or recursion. `\d` is `[0-9]`, `\w` the 63 ASCII word characters, and `.` excludes LF, CR, U+2028
  and U+2029.
- `replace` takes ECMA-262's template, not a `SubstitutionString`.
- `split` is Base's; `ecmasplit` is JavaScript's.

The [getting-started page](getting-started.md) has the full list.
