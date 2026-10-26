# A match allocates nothing once the working memory has grown to what the pattern and the text need: not a test, not a
# global search into a Captures, and not a read of the groups (allocations.rs of the Rust crate, the Java engine's
# AllocationTest, the Go engine's alloc_test.go). Each case reaches one of the searches for where a match starts.

function tests_and_counts(re, text8, text16, text)
    occursin(re, text8) && occursin(re, text16) && occursin(re, text) || error("no match")
    count(re, text8) > 0 && count(re, text16) > 0 || error("no matches")
    return nothing
end

function reads_the_groups(re, c, text8, text16, text)
    for m in eachmatch!(c, text8)
    end
    for m in eachmatch!(c, text16)
    end
    match!(c, text8) && match!(c, text) && match!(c, text16) || error("no match")
    return nothing
end

least_allocated(f, args...) = (f(args...); f(args...); minimum(@allocated(f(args...)) for _ in 1:5))

@testset "a warm match allocates nothing" begin
    text = "The year 2026, the month 10; Ünïcödé text, 😀 and more letters after it. "^20
    text8, text16 = Utf8Text(text), transcode(UInt16, text)
    cases = [("\\d+", ""), ("(?<y>\\d{4})\\D+(\\d+)", "u"), ("text|month", "i"), ("(?<=the )\\w+", "u"), ("(t|e)\\1", ""),
        ("\\p{L}+", "u"), ("[\\p{L}--[a-z]]+", "v"), ("^.*\$", "m"), ("\\bt\\w*\\b", "gi"),
        # The searches for where a match starts: a literal, several (packed over UTF-16), the case forms, the windows
        # with the reverse automaton, the search after loops, the forward automaton with the skip window, and the shapes
        # answered without the matcher.
        ("letters", ""), ("year|month|text|letters", ""), ("the", "i"), ("year.{0,25}month|month.{0,25}year", ""),
        ("\\s[a-z]{0,12}ers\\s", ""), ("\\w+\\s+month", ""), ("\\d\\d:?\\d\\d", ""), (".*", "s"), ("[^\\n]*", ""),
        ("\\p{L}", "u")]
    for (pattern, flags) in cases, timeout in (nothing, 60.0)
        # With no timeout, and with one, whose clock is read as the match goes.
        re = EcmaRegex(pattern, flags; match_timeout=timeout)
        c = Captures(re)
        @test (pattern, flags, timeout, least_allocated(tests_and_counts, re, text8, text16, text)) == (pattern, flags, timeout, 0)
        @test (pattern, flags, timeout, least_allocated(reads_the_groups, re, c, text8, text16, text)) == (pattern, flags, timeout, 0)
    end
end
