# Getting started with Julia

`CorvusRegexEcma262` is a pure Julia engine whose patterns have the grammar and the answers of JavaScript's `RegExp`,
held to V8's answers on the ECMA-262 test data, over UTF-8 strings and vectors of UTF-16 code units. It works through
Base's own verbs: `occursin`, `match`, `eachmatch`, `findfirst`, `findall`, `count`, `replace` and `split`.

## Install

```
using Pkg
Pkg.add("CorvusRegexEcma262")
```

It needs Julia 1.10 or later, and has no dependencies.

## Compile a pattern

`EcmaRegex` takes a pattern and its flags as `new RegExp(pattern, flags)` takes them: `d`, `g`, `i`, `m`, `s`, `u`, `v`
and `y`; the `ecma"..."flags` string macro writes one into a program. Without `u` or `v` a pattern is read by the Annex
B grammar and matched by UTF-16 code unit, as ECMA-262 reads it; with them, by code point. A pattern that is not valid
throws `InvalidPatternError` (or `FlagsError`, or `TooLargeError`); `try_compile` returns the error in place of
throwing.

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

date = ecma"(?<year>\d{4})-(?<month>\d{2})"gu               # the same as EcmaRegex(pattern, "gu")
@assert date isa EcmaRegex

@assert try EcmaRegex("a{2,1}", "u"); false catch e; e isa C.InvalidPatternError end

re, err = C.try_compile("a", "uv"; match_timeout=1)
@assert re === nothing && err isa C.FlagsError
@assert !C.isvalid_pattern("(?<n>a)(?<n>b)", "u")
```

## Match

A match is an `EcmaMatch`, read as a `RegexMatch` is. Positions are Julia's string indices, 1-based byte offsets into
the UTF-8 text.

```julia
using CorvusRegexEcma262

date = ecma"(?<year>\d{4})-(?<month>\d{2})"gu
text = "due 2026-10, then 2027-01"

@assert occursin(date, text)

m = match(date, text)
@assert m.match == "2026-10" && m.offset == 5
@assert m[:year] == "2026" && m[2] == "10"
@assert findfirst(date, text) == 5:11

# Every match of a global search, as matchAll makes it.
@assert [m.match for m in eachmatch(date, text)] == ["2026-10", "2027-01"]
@assert count(date, text) == 2

# replace takes ECMA-262's template, with every $ form, for every match.
@assert replace(text, date => "\$<month>/\$1") == "due 10/2026, then 01/2027"

# ecmasplit puts what the groups captured between the pieces, as String.prototype.split does.
@assert ecmasplit("a ; b;c", ecma"\s*(;)\s*") == ["a", ";", "b", ";", "c"]
```

## UTF-8 and UTF-16

A string is UTF-8, and is checked before it is read: text that is not UTF-8 throws `EncodingError`, and is never
matched or read as U+FFFD. `Utf8Text` checks a text once, for a text matched many times. A `Vector{UInt16}` is UTF-16
code units, lone surrogates and all, with ranges in code units.

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

dot_b = ecma".b"u
@assert findfirst(dot_b, "a😀b") == 2:6                       # bytes of UTF-8
@assert findfirst(dot_b, transcode(UInt16, "a😀b")) == 2:4    # UTF-16 code units

text = Utf8Text("a😀b")                                        # checked once
@assert occursin(dot_b, text)

@assert try occursin(dot_b, String(UInt8[0xff])); false catch e; e isa C.EncodingError end
```

## Patterns and texts from outside

A match has no limit by default. A program that matches a pattern or a text it did not write gives the pattern a match
timeout in seconds, as a .NET `Regex` has: a match that runs past it throws `MatchTimeoutError`, and one whose
backtracking memory reaches its cap `MatchMemoryError`. `set_default_match_timeout!` sets the timeout of every
pattern compiled after it.

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

slow = EcmaRegex("^(?:(a+)\\1*)+\$", ""; match_timeout=0.1)
@assert try occursin(slow, "a"^60 * "b"); false catch e; e isa C.MatchTimeoutError end
```

## The edition and the version of Unicode

JSON Schema 2020-12 names the grammar of ECMAScript 2020. `edition=:es2020` refuses what later editions added: the `d`
and `v` flags, modifier groups, a group name used twice, and property names outside the 2020 tables. The version of
Unicode is chosen apart from it with `unicode_version`: 13, 17, 18, `:latest` (18), or `:default` for V8's (17). Both
are read when the pattern is compiled, so a match costs the same whatever they are.

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

greek = EcmaRegex("^\\p{Script=Greek}+\$", "u"; match_timeout=1, edition=:es2020, unicode_version=13)
@assert occursin(greek, "αβγ")

# Vithkuqi is in Unicode 14 and later, so not in Unicode 13.
@assert !C.isvalid_pattern("\\p{Script=Vithkuqi}", "u"; unicode_version=13)
```

## Differences from Julia's Regex

- The grammar is ECMA-262's, not PCRE's. A group is named `(?<name>...)` in both, but the flags are a string as
  `RegExp` takes them, and `(?i:...)` groups set them inside a pattern; there is no `(?i)` prefix for the whole
  pattern, no possessive quantifiers, no atomic groups, no `\A` or `\z`, and no recursion.
- `\d` is `[0-9]`, `\w` the 63 ASCII word characters, `\s` ECMAScript's white space and line terminators, and `.`
  excludes LF, CR, U+2028 and U+2029.
- `replace` takes ECMA-262's template (`$1`, `$<name>`, `$&`, `` $` ``, `$'`), not a `SubstitutionString` (`s"\1"`).
- `split` splits as Base's does; `ecmasplit` is JavaScript's, which puts what the groups captured between the pieces.
- PCRE has no limit on a match's time. Here a pattern without a backreference is matched in time linear in the text,
  and a pattern from outside should be given a `match_timeout`, which bounds every match.

## Where next

- [The API reference](api.md), generated from the package's docstrings.
- [The README](../README.md).
- [The benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), with every engine measured nightly.
