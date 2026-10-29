# Getting started with Julia

## Introduction

`CorvusRegexEcma262` is a Julia package whose patterns answer as ECMAScript does. Where Julia's `Regex` has PCRE's
grammar and its meaning for `\d`, `\w`, `\s`, `.`, case folding and Unicode properties, this package has ECMA-262's,
so a pattern written for JavaScript, or taken from a JSON Schema, matches the same texts here as it does there. It is a
port of the corvus-regex-ecma262 Rust crate in pure Julia, held to V8's answers on the ECMA-262 test data, and it works
through Base's own verbs: `occursin`, `match`, `eachmatch`, `findfirst`, `findall`, `count`, `replace` and `split`.

This guide covers:

- **Setup**: adding the package.
- **Patterns and flags**: the flags are ECMA-262's letters, and what each one does.
- **The edition and the version of Unicode**: the grammar of ECMAScript 2020, and the Unicode tables a pattern reads.
- **Matching**: Base's verbs over an `EcmaRegex`, and `Captures` with `match!`, which allocate nothing.
- **Timeouts**: the limit of time and of memory a match may take.
- **UTF-8 and UTF-16**: strings as UTF-8, checked once with `Utf8Text`, and vectors of UTF-16 code units.
- **Differences from Regex**: what to expect when the two meet.

## Setup

```
using Pkg
Pkg.add("CorvusRegexEcma262")
```

It needs Julia 1.10 or later, on any platform Julia runs on, and has no dependencies.

```julia
using CorvusRegexEcma262
```

## Patterns and flags

A pattern is written as it would be in JavaScript, and the flags are the letters `RegExp` takes, as a string; the
`ecma"..."flags` string macro writes one into a program:

| Flag | Meaning |
|---|---|
| `d` | Accepted for completeness; indices are always kept. |
| `g` | Accepted as `RegExp` takes it. `replace` replaces every match whatever the flags, as Base's does (`count = 1` for the first). |
| `i` | Canonicalize of the mode in force: simple case folding with `u` or `v`, `toUpperCase` without. Never the locale. |
| `m` | `^` and `$` at line terminators. |
| `s` | The dot matches line terminators. |
| `u` | The `u` flag grammar; matched by code point. |
| `v` | Set notation and properties of strings; matched by code point. `u` and `v` together is an error, as in ECMA-262. |
| `y` | A match only at the start position. |

```julia
using CorvusRegexEcma262

a = ecma"\p{Script=Greek}+"u                     # the same as EcmaRegex(pattern, "u")
b = ecma"[[a-z]--[aeiou]]+"v
c = ecma"^(?<year>\d{4})-(?<month>\d{2})$"u

@assert occursin(a, "αβγ")
@assert occursin(b, "rhythm")
@assert match(c, "2026-10")[:month] == "10"
```

With no flag the pattern is read with the Annex B grammar and matched by UTF-16 code unit, which is what ECMA-262 does
with no flag. JSON Schema's reading, the `u` flag first and Annex B when that refuses, is two calls of `try_compile`,
which throws nothing and takes the match timeout, so no default timeout is needed:

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

function schema_pattern(pattern)
    re, err = C.try_compile(pattern, "u"; match_timeout = 1)
    re === nothing || return re
    re, err = C.try_compile(pattern, ""; match_timeout = 1)
    re === nothing ? throw(err) : re
end

@assert string(schema_pattern("^\\p{L}+\$").flags) == "u"
@assert string(schema_pattern("\\-").flags) == ""        # an identity escape, which only Annex B allows
```

A pattern that is not valid throws an `InvalidPatternError`, whose `msg` says why and whose `offset` says where;
invalid flags throw a `FlagsError`. Every pattern has deterministic limits of size, and a `TooLargeError` says when one
is passed. `try_compile` returns the same error in place of throwing it.

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

@assert try EcmaRegex("a{2,1}", "u"); false catch e; e isa C.InvalidPatternError end

re, err = C.try_compile("a", "uv"; match_timeout = 1)
@assert re === nothing && err isa C.FlagsError
@assert !C.isvalid_pattern("(?<n>a)(?<n>b)", "u")
```

## The edition and the version of Unicode

JSON Schema 2020-12 names the grammar of ECMAScript 2020. `edition = :es2020` refuses what later editions added, and
nothing else: the `d` and `v` flags, modifier groups such as `(?i:...)`, a group name used by two groups, and a
property name or value that is not in the 2020 tables (such as `\p{Script=Yezidi}`). A pattern it accepts has the same
answers as in today's grammar.

The version of Unicode is chosen apart from the edition: `unicode_version` is 13, 17, 18, `:latest` (18 today) or
`:default`, the version of the V8 the answers are held to (17 today). It decides the members of each `\p{...}`, the
characters of a group name and the case folding of the `i` flag. The `unicode_version` field reports the version a
pattern was compiled with. Both are read when the pattern is compiled, so a match costs the same whichever is chosen.

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

# ECMAScript 2020 as its edition was published, with the Unicode of its year.
greek = EcmaRegex("^\\p{Script=Greek}+\$", "u"; match_timeout = 1, edition = :es2020, unicode_version = 13)
@assert occursin(greek, "αβγ") && greek.unicode_version == 13

# Vithkuqi is in Unicode 14 and later, so not in Unicode 13.
@assert !C.isvalid_pattern("\\p{Script=Vithkuqi}", "u"; unicode_version = 13)
```

## Matching

The verbs are Base's, with the position as an argument where JavaScript keeps `lastIndex`. A match is an `EcmaMatch`,
read as a `RegexMatch` is, and positions are Julia's string indices, 1-based byte offsets into the UTF-8 text.

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

# replace takes ECMA-262's template, with every $ form, for every match (count = 1 for the first).
@assert replace(text, date => "\$<month>/\$1") == "due 10/2026, then 01/2027"

# ecmasplit puts what the groups captured between the pieces; a group that did not take part is nothing.
@assert ecmasplit("a ; b;c", ecma"\s*(;)\s*") == ["a", ";", "b", ";", "c"]
```

`match(re, s, i)` is `exec` with `lastIndex` set to `i - 1`, and `y` anchors it there. `match`, `eachmatch` and
`replace` allocate what they return. `occursin`, `count` and `match!`, which writes a match's groups into a `Captures`
made once, allocate nothing once it has grown:

```julia
using CorvusRegexEcma262

date = ecma"(?<year>\d{4})-(?<month>\d{2})"u
c = Captures(date)
@assert match!(c, "due 2026-10")
@assert capture_range(c, 1) == 5:8
```

A compiled pattern holds no mutable state that a match changes, so it is safe to share between tasks and threads.

## Timeouts

A match has no limit by default. A pattern compiled with `match_timeout` (in seconds) abandons a match that reaches it
with a `MatchTimeoutError`, and one that reaches the cap on backtracking memory the timeout brings with a
`MatchMemoryError`, whatever the pattern:

```julia
using CorvusRegexEcma262
const C = CorvusRegexEcma262

slow = EcmaRegex("^(?:(a+)\\1*)+\$", ""; match_timeout = 0.1)
@assert try occursin(slow, "a"^60 * "b"); false catch e; e isa C.MatchTimeoutError end
```

A pattern compiled without a timeout takes `default_match_timeout()`, which is `nothing` unless
`set_default_match_timeout!` sets it. A program that matches patterns or texts from outside should set one, for example
with `CorvusRegexEcma262.set_default_match_timeout!(1)` when it starts.

A pattern without a backreference is matched in time linear in the text, and no pattern can overflow the stack, so the
timeout is what bounds the others.

## UTF-8 and UTF-16

A `String` is UTF-8, matched as its bytes with no transcoding, and positions are byte offsets. It is checked before it
is read: text that is not UTF-8 throws an `EncodingError`, and is never matched or read as U+FFFD. `Utf8Text` checks a
text once, for a text matched many times. A `Vector{UInt16}` is UTF-16 code units, lone surrogates and all, with
ranges in code units.

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

Under the `u` and `v` flags a character is a code point in both encodings, so a class, a dot or a quantifier takes a
four-byte sequence as one character. With no flag ECMA-262 matches by UTF-16 code unit; over UTF-8 the package keeps
that meaning, so a match can start or end between the halves of a character beyond the Basic Multilingual Plane, at
the character's third byte.

## Differences from Regex

The verbs are Base's; the meaning follows ECMA-262. The differences a user coming from Julia's `Regex` will meet:

- **The grammar.** No `(?i)` inline option (ECMA-262 has `(?i:...)` groups), no atomic groups, no possessive
  quantifiers, no `\A` and `\z`, no conditionals and no recursion. The flags are a separate string.
- **The character classes.** `\d` is `[0-9]`, `\w` is the 63 ASCII word characters, `\s` is ECMAScript's white space
  and line terminators, and `.` excludes the four line terminators (LF, CR, U+2028, U+2029).
- **Replacement.** `replace` takes ECMA-262's template (`$1`, `$<name>`, `$&`, `` $` ``, `$'`), not a
  `SubstitutionString` (`s"\1"`).
- **Split.** `split` splits as Base's does; `ecmasplit` is JavaScript's, which puts what the groups captured between
  the pieces.
- **Timeouts.** PCRE has no limit on a match's time. Here a pattern without a backreference is matched in time linear
  in the text, and a timeout bounds the others.
