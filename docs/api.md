# API reference

The public names of `CorvusRegexECMA262`, generated from the package's docstrings by `tools/docs/gen-api.jl`.
[Getting started](getting-started.md) shows them at work.

## Compiling

### EcmaRegex

```julia
EcmaRegex(pattern, flags = ""; match_timeout = default_match_timeout(), edition = :current, unicode_version = :default)
```

A pattern compiled as `new RegExp(pattern, flags)` compiles it: with the u or v flag by the grammar of the u flag and
matched by code point; with neither by the Annex B grammar and matched by UTF-16 code unit. The i, m and s flags are the
modifiers in force at the start of the pattern, which a modifier group such as `(?i:...)` changes for part of it.

A pattern can have a match timeout in seconds, as a Regex of .NET has: the time each match may take, which brings a cap
on the memory of its backtracking with it. A match that reaches a limit throws a MatchTimeoutError or a
MatchMemoryError. A pattern without a timeout never reaches a limit.

`edition` is the edition of ECMA-262 whose grammar the pattern is read with: `:current`, today's, or `:es2020`, the
grammar of ECMAScript 2020 that JSON Schema 2020-12 names, which refuses what later editions added (the d and v flags,
modifier groups, a group name used twice, and property names outside its tables). `unicode_version` is the version of
Unicode whose tables it is read with, independent of the edition: `:default` (V8's, 17 today), `13`, `17`, `18` or
`:latest` (18 today). Both are settled when the pattern is compiled and cost a match nothing.

What a pattern is can be read from its fields: `pattern`, the pattern as it was given; `flags`, which `string` writes
as RegExp.prototype.flags does; `edition`; and `unicode_version`, resolved to 13, 17 or 18.

An invalid pattern throws an InvalidPatternError, a pattern over a limit of size a TooLargeError, and invalid flags a
FlagsError. A compiled pattern is safe to share between tasks.

### @ecma_str

```julia
@ecma_str pattern flags
```

The pattern compiled when the code is, as `r"..."` is: `ecma"(?<year>\d{4})"u`.

### try_compile

```julia
try_compile(pattern, flags = ""; match_timeout = default_match_timeout(), edition = :current, unicode_version = :default)
```

`EcmaRegex(pattern, flags; ...)` without throwing for the pattern or the flags: `(regex, nothing)`, or `(nothing, error)`
with the InvalidPatternError, TooLargeError, FlagsError or EncodingError of why it was not compiled. A validator that
compiles patterns from outside takes this form, and gives each a match timeout of its own.

### tryparse

```julia
tryparse(EcmaRegex, pattern, flags = ""; kwargs...)
```

The compiled pattern, or `nothing` when it is not valid (see `try_compile`, which gives the error too).

### isvalid_pattern

```julia
isvalid_pattern(pattern, flags = ""; edition = :current, unicode_version = :default)
```

Whether a pattern is valid in the grammar of ECMA-262 for the flags, of an edition and under a version of Unicode. It
asks the grammar only: unlike `EcmaRegex` and `try_compile`, which read the pattern as compiling it does, it does not
apply the limits of size (`MAX_PATTERN_LENGTH`, `MAX_NESTING`, `MAX_SIZE`), so a pattern too large to compile is valid
here when its grammar is. It reads the pattern in place with stacks of its own, so no pattern can overflow the stack,
and once its stacks have grown to what the patterns need it allocates nothing. The u and v flags choose the grammar,
and the others do not change it. It is `false` too for flags that are not valid, alone or with the edition, and for a
pattern that is not UTF-8. It is the check a JSON Schema `format: regex` needs, as the .NET engine's `IsValidPattern`
and the Rust crate's `is_valid_pattern` are.

```julia
deep = "("^5000 * ")"^5000
isvalid_pattern(deep, "u")                               # true, though it is too large to compile
isvalid_pattern("(?i:a)", "u"; edition = :es2020)        # false: ECMAScript 2020 has no modifier groups
```

### set_default_match_timeout!

```julia
set_default_match_timeout!(seconds)
```

Gives every pattern compiled after it, without a timeout of its own, the match timeout. `nothing` or 0 is no timeout.

### default_match_timeout

The match timeout a pattern compiled now without one of its own takes, in seconds, or `nothing`.

## Matching

### occursin

```julia
occursin(re::EcmaRegex, s)
```

Whether the pattern matches the text: a string (checked to be UTF-8), a Utf8Text, or a vector of UTF-16 code units. With the
y flag the match must start at the start.

### match

```julia
match(re::EcmaRegex, s, i = 1)
```

The first match at or after index `i` (at `i` alone with the y flag), or `nothing`.

### findfirst, findnext

```julia
findnext(re::EcmaRegex, s, i)
```

The code units of the first match at or after index `i`, as a range, or `nothing`.

### eachmatch

```julia
eachmatch(re::EcmaRegex, s)
```

The matches of a global search of the text, each an EcmaMatch, as String.prototype.matchAll gives them.

### findall

```julia
findall(re::EcmaRegex, s)
```

The code units of each match of a global search, as ranges.

### count

```julia
count(re::EcmaRegex, s)
```

The number of matches of a global search of the text.

### replace

```julia
replace(s, re::EcmaRegex => template; count)
```

The text with every match (at most `count`) replaced by the template, with its $ forms ($$, $&, $`, $', $n, $nn
and $<name>) replaced as String.prototype.replace replaces them. Over a vector of UTF-16 code units the template is one
too.

### split

```julia
split(s, re::EcmaRegex; limit = 0, keepempty = true)
```

The pieces of the text between the matches, as `split` with a Regex gives them: at most `limit` pieces when it is more
than 0, the empty ones dropped when `keepempty` is false. The groups of the matches are not among them; `ecmasplit`
gives String.prototype.split's answer, which has them.

### ecmasplit

```julia
ecmasplit(s, re::EcmaRegex; limit = -1)
```

The text split around the matches as String.prototype.split splits it: the pieces, with the groups of each match
between them (`nothing` for a group that did not take part), at most `limit` items (all when it is below 0).

## Matches and texts

### EcmaMatch

```julia
EcmaMatch
```

A match of an EcmaRegex, read as a RegexMatch is: `m.match`, `m.captures` (`nothing` for a group that did not take
part), `m.offset` and `m.offsets` (0 for a group that did not take part), 1-based in code units; `m[1]`, `m[:name]` and
`m["name"]`.

### Utf8Text

```julia
Utf8Text(s)
```

UTF-8 text that has been checked once, so that the methods that take it check nothing. A program that matches one text
many times makes a Utf8Text of it and pays for the check once. Utf8Text that is not UTF-8 throws an EncodingError.

### Captures

```julia
Captures(re)
```

The start and end of a match and of each group of a pattern. A match into one with `match!` allocates nothing once the
working memory has grown, so a program that matches many times makes one and passes it to each match. A Captures is not
safe to share between tasks.

### match!

```julia
match!(c::Captures, s, i = 1)
```

Finds the first match at or after index `i` of the text into the Captures, and reports whether there was one. It
allocates nothing once the working memory has grown.

### eachmatch!

```julia
eachmatch!(c::Captures, s)
```

The matches of a global search of the text, as String.prototype.matchAll gives them, each read into the Captures,
which the iteration yields every time: a global search that allocates nothing once the working memory has grown.

```julia
c = Captures(re)
for m in eachmatch!(c, text)
    r = capture_range(m, 1)
end
```

### capture_range

```julia
capture_range(c::Captures, g = 0)
```

The code units of group `g` of the last match (0 for the whole match), as a range, or `nothing` for a group that did not
take part.

## Errors

### InvalidPatternError

```julia
InvalidPatternError(pattern, message, offset)
```

A pattern that is not valid under the grammar its flags choose: the reason, and the offset in the pattern's characters
(UTF-16 code units without the u or v flag).

### FlagsError

```julia
FlagsError(message)
```

Flags that are not valid: a flag that is not one of dgimsuvy, a flag given twice, or u with v.

### TooLargeError

```julia
TooLargeError(limit, value)
```

A pattern over one of the limits of size: `limit` names it and `value` is its value. The pattern was not read to its
end, so the error says nothing of whether it is valid.

### EncodingError

```julia
EncodingError(message)
```

A pattern or a text that is not UTF-8, which is refused, never read as U+FFFD.

### MatchTimeoutError

```julia
MatchTimeoutError(limit)
```

A match ran for longer than its limit, in seconds. It is not an answer.

### MatchMemoryError

```julia
MatchMemoryError()
```

A match needed more backtracking memory than its limit: its stack reached MAX_STACK entries. It is not an answer.
