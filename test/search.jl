# The tests of the searches for where a match starts, and of the automata they use, ported from the Rust crate's
# tests.rs (by way of the Java engine's SearchTest and the Go engine's search_test.go): each search finds what trying
# every position finds.

"A pattern compiled as every other is, and with the search that tries every position its first set allows, or nothing
when the pattern is not valid."
function searched_and_plain(pattern, flags)
    searched = try
        EcmaRegex(pattern, flags)
    catch
        return nothing, nothing
    end
    C.NO_SEARCH[] = true
    plain = try
        EcmaRegex(pattern, flags)
    finally
        C.NO_SEARCH[] = false
    end
    # The program that records the groups is built on the first use, so it is built here, without the search.
    C.NO_SEARCH[] = true
    try
        C.caps_program(plain)
    finally
        C.NO_SEARCH[] = false
    end
    C.caps_program(searched)
    return searched, plain
end

all_spans(re, input, submatch) = C.find_all(re, input, -1, submatch)

function xorshift(seed::UInt64)
    state = Ref(seed)
    return () -> begin
        s = state[]
        s ⊻= s << 13
        s ⊻= s >> 7
        s ⊻= s << 17
        state[] = s
        s
    end
end

@testset "the searches find what every position finds" begin
    patterns = [("Sherlock", ""), ("Sherlock|Street", ""), ("Sherlock|Holmes|Watson|Irene|Adler|John|Baker", "i"),
        ("Sher[a-z]+|Hol[a-z]+", "i"), ("[a-q][^u-z]{13}x", ""), ("[a-zA-Z]+ing", ""),
        ("\\s[a-zA-Z]{0,12}ing\\s", ""), ("\\w+\\s+Holmes", ""), ("\\w+\\s+Holmes\\s+\\w+", ""), ("\\b\\w+n\\b", ""),
        ("\\w+n\\b", ""), (".*\$", ""), ("(?:.)??\$", ""), (".*\\s", ""), ("abcd|bc", ""), ("(?:x|y)*z|q", ""),
        ("\\b(?:the|he)\\b", "i"), ("Holmes.{0,25}Watson|Watson.{0,25}Holmes", ""), ("Tom.{1,5}er|er.{1,5}Tom", ""),
        ("\\w+n(?=\\s)", ""), ("[a-z]+n\\B", "i"), ("\\w+\\s+Holmes\$", "m"), ("[a-z]+ing\\b|x", ""),
        (".{0,2}(Tom|Sawyer|Huckleberry|Finn)", ""), (".{2,4}(Tom|Sawyer|Huckleberry|Finn)", ""),
        ("Tom.{10,25}river|river.{10,25}Tom", ""), ("([A-Za-z]awyer|[A-Za-z]inn)\\s", ""),
        ("[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+", ""), ("\\p{Sm}", ""),
        ("(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])", ""),
        ("Шерлок Холмс|Джон Уотсон", "i"), ("夏洛克|福尔摩斯", ""), ("sk", "i"), ("ks", "i"),
        ("\\u{1F600}a|b\\u{10400}", ""), ("a\\u{1F600}", ""), ("\\ud83d", ""), ("x*y", ""), ("[a-c]*b+c", ""),
        ("(?:ab)?c", ""), ("\\béé\\w*", ""), ("(?<=a)b|c", ""), ("[\\p{L}--[a-z]]+t", "v"), ("[\\q{abc|de}x]y", "v"),
        ("\\w+", ""), (".*", ""), (".+", "s"), ("[^\\n]*", ""), ("[^\\n.]+", ""), ("\\p{L}", ""), ("[\\ud800-\\udfff]", ""),
        ("Tom|river|Tomas", ""), ("ab|a", ""), ("sherlock|holmes|k", "i"), ("\\u{1F600}|Ш", ""),
        # A start that one occurrence's terms do not allow, and a later occurrence's do, is tried first.
        ("(|([^a]|[^a][^a]){2,4}){2}(\\3){3,5}?x", ""), ("[^a]{0,3}(?:xx|x)", ""), ("\\s[a-zA-Z]{0,12}ing\\s", ""),
        # A window of positions read one unit at a time (SkipWin).
        ("\\d{3}-\\d{4}", ""), ("[0-9]+\\.[0-9]+", ""), ("(?:\\d+\\.){3}\\d+", ""), ("\\b\\d\\d:\\d\\d\\b", ""),
        ("[A-Z]{2}\\d{2}", ""), ("(?:1|22|333)\\.5\\.\\d", ""), ("\\d{2}[é5]\\d", "u"), ("\\d{3}[éèêë5]", "u"),
        # An occurrence of the one literal every match starts with, which the automaton goes on after.
        ("^abc", "m"), ("x{0}^abc", ""), ("\\babc\\b", ""), ("abc\\s+\\w+", "")]
    alphabet = ["a", "b", "c", "e", "i", "k", "n", "s", "t", "x", "y", "g", "S", "K", " ", "\n", ".", "@", "1", "2",
        "5", "+", "=", "ſ", "K", "é", "Ш", "е", "р", "л", "о", "к", "Х", "夏", "洛", "克", "😀", "𐐀", "ing", "Tom",
        "river", "Holmes", "Sherlock", "sherLOCK", "awyer", "inn", "Watson", "Шерлок Холмс", "夏洛克", "abc", "de",
        "0", "25", "255.", "192.168.", "333.5.", "12:34", "555-1234", "AB12", "123é"]
    next = xorshift(0x2545_F491_4F6C_DD1D)
    texts = [join(alphabet[next()%length(alphabet)+1] for _ in 1:1+Int(next() % 300)) for _ in 1:60]
    failures = 0
    for (pattern, base) in patterns, mode in ("", "u")
        flags = base == "v" ? "v" : base * mode
        searched, plain = searched_and_plain(pattern, flags)
        searched === nothing && continue
        @test plain.prog.search.plan == C.PLAN_SCAN
        for text in texts, input in (codeunits(text), transcode(UInt16, text)), submatch in (true, false)
            a, b = all_spans(plain, input, submatch), all_spans(searched, input, submatch)
            if a != b
                failures += 1
                failures <= 5 && @error "the searched and the plain search differ" pattern flags text eltype(input) submatch
            end
        end
    end
    @test failures == 0
end

@testset "the searches find the starts the fuzzer found" begin
    cases = [("\\b\\w+n\\b", "", "a nation"), ("\\b\\w+n\\b", "", "an nation nn nan noon"),
        ("\\w+\\s+Holmes", "", "Holmes Holmes"), ("\\b\\d*\\s*a\\b", "", " a"), ("\\b\\d*\\W*x\\b", "s", " ééx"),
        ("\\b\\d*\\W*x", "", "a1 x"), ("\\b\\d*\\W+\\w+ab", "", "ab0 aab"),
        ("\\b\\w*[\\u{1F600}-\\u{1F64F}]*S\\B", "u", "😀S_n😀S"), ("\\W+[a-z]*\\W*a", "m", " a"),
        ("[a-zéè]+\\d*[a-z]+on", "i", " ONaON"), ("\\w+?[^\\w\\s]*\\d+?n", "im", "000n"), ("\\w*\\W+-\$", "", " a\u00a0-a--"),
        ("\\w*[^\\w\\s]+k\$", "", "---_-ka.k"), ("\\b[0-9a-f]*ét", "", "\nét0aét"), (".{1,3}(?:on|\\.).", "", "😀😀😀ona on"),
        ("\\b[^\\n]{1,3}(?:k|\\.)\\b", "im", "k 😀nk"), ("[^\\n]{1,3}(?:é|a)", "", "中中中a"), ("\\B[^\\w\\s]{1,3}(?:a|n)", "", "a😀a")]
    for (pattern, flags, text) in cases, mode in ("", "u")
        searched, plain = searched_and_plain(pattern, flags * mode)
        searched === nothing && continue
        for input in (transcode(UInt16, text), codeunits(text))
            @test all_spans(plain, input, false) == all_spans(searched, input, false)
        end
    end
end

@testset "a literal with a rare byte is found as any other" begin
    next = xorshift(UInt64(0x2f6b1c3d))
    below(n) = Int(next() % n)
    for literal in ("zqj", "aqj", "qq", "Xa", "abZ", "jj j")
        re = EcmaRegex(literal, "g")
        for _ in 1:200
            text = String([UInt8("abqjzZX "[below(8)+1]) for _ in 1:below(200)])
            want = Int[]
            i = 1
            while (r = findnext(literal, text, i)) !== nothing
                push!(want, first(r) - 1)
                i = last(r) + 1
            end
            @test [m[1] for m in C.find_all(re, codeunits(text), -1, false)] == want
            @test [m[1] for m in C.find_all(re, transcode(UInt16, text), -1, false)] == want
        end
    end
end

@testset "a run of the dot with the s flag is the rest of the text" begin
    texts = [UInt16[], UInt16['a', 0xD800], UInt16['a', 0xDC00], UInt16[0xDC00, 'a', 0xD83D, 0xDE00], UInt16[0xD83D, 0xDE00],
        UInt16[0xDC00, 'b', 0xD83D, 0xDE00, 0xD800, 'c', 0xDBFF]]
    span(slots) = slots === nothing ? nothing : slots[1:2]
    find_at(re, text, start) = (s = Vector{Int}(undef, 2 * (re.groups + 1)); C.exec_slots(re, text, start, re.flags.sticky, s)[3] ? s : nothing)
    for flags in ("s", "su", "sv", "sy", "suy")
        unicode = occursin('u', flags) || occursin('v', flags)
        shortcut, matcher = EcmaRegex(".*", flags), EcmaRegex("(.*)", flags)
        plus, plus_matcher = EcmaRegex(".+", flags), EcmaRegex("(.+)", flags)
        @test shortcut.prog.search.shape == C.SHAPE_LOOP
        for text in texts, start in 0:length(text)
            from = unicode && C.mid_pair(text, start) ? start - 1 : start
            got = span(find_at(shortcut, text, start))
            @test got == span(find_at(matcher, text, start))
            @test got == [from, length(text)]
            got = span(find_at(plus, text, start))
            @test got == span(find_at(plus_matcher, text, start))
            @test got == (from < length(text) ? [from, length(text)] : nothing)
        end
    end
end

@testset "the forward automaton is kept for the scan" begin
    re = EcmaRegex("(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])")
    @test C.forward(re.prog) !== nothing
    @test re.prog.skip !== nothing
    C.NO_SEARCH[] = true
    try
        @test C.forward(EcmaRegex("\\d{3}-\\d{4}").prog) === nothing
    finally
        C.NO_SEARCH[] = false
    end
end

@testset "the UTF-16 search for a rare unit finds what every position finds" begin
    # A literal found by the search for its rarest unit, wherever that is in it, with the starts that unit lets through
    # and the literal does not; and up to four literals that share a rare first unit.
    cases = [("Twain", "u", "Twi Twa Twain Twain Twai"), ("aqj", "u", "q aq aqj qj aqjaqj"), ("zqj", "", "zq zqj"),
        ("Шерлок", "u", "Ш Шерлок шерлок"), ("夏洛克", "u", "夏洛 夏洛克夏洛克"), ("a😀b", "u", "a😀 a😀b"),
        ("Sherlock|Street", "u", "Sher Street Sherlock St"), ("Sherlock|Street", "y", "Street")]
    for (pattern, flags, t) in cases
        searched, plain = searched_and_plain(pattern, flags * "g")
        text = transcode(UInt16, t)
        @test all_spans(plain, text, false) == all_spans(searched, text, false)
        found(re, from) = ((a, b, f) = C.exec_slots(re, text, from, re.flags.sticky, nothing); f ? (a, b) : nothing)
        for from in 0:length(text)
            @test found(searched, from) == found(plain, from)
        end
    end
end

@testset "the plans are taken" begin
    cases = [("Sherlock", "", C.PLAN_WINDOWS, C.SHAPE_LITERALS, false),
        ("Sherlock|Holmes|Watson", "i", C.PLAN_WINDOWS, C.SHAPE_FORMS, false),
        ("[a-zA-Z]+ing", "", C.PLAN_AFTER_LOOPS, C.SHAPE_NONE, false),
        (".{0,2}(Tom|Sawyer|Huckleberry|Finn)", "", C.PLAN_WINDOWS, C.SHAPE_NONE, true),
        ("\\w+", "", C.PLAN_SCAN, C.SHAPE_LOOP, false), ("\\p{Sm}", "u", C.PLAN_SCAN, C.SHAPE_SET, false)]
    for (pattern, flags, plan, shape, reverse) in cases
        s = EcmaRegex(pattern, flags).prog.search
        @test (pattern, s.plan, s.shape, s.reverse !== nothing) == (pattern, plan, shape, reverse)
    end
    re = EcmaRegex("Sherlock\\s+\\w+")
    @test re.prog.after_literal !== nothing && re.prog.anchored_dfa !== nothing
    @test EcmaRegex("\\b\\w+n\\b").prog.search.leading_word_boundary
end
