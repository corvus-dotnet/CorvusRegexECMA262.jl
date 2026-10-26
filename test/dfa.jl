# The automaton over ASCII agrees with the matcher over ASCII texts, for patterns it takes, and decides every ASCII
# text.
@testset "the automaton agrees with the matcher" begin
    patterns = [("^[a-z]+\\d*\$", ""), ("\\bfoo\\b", ""), ("\\Bo+\\B", "u"), ("(a|ab)(c|bcd)(d*)", ""), ("colou?r", "i"),
        ("^\$", ""), ("x{2,4}y", ""), ("[^\\s]+@[^\\s]+", "u"), ("a|", ""), ("(?:ab)*c", "")]
    texts = ["", "a", "abc123", "foo", "a foo b", "food", "xxy", "xxxxxy", "COLOR", "colour", "a@b", "abcd", "ababc",
        "éfoo", " oo "]
    for (pattern, flags) in patterns
        re = EcmaRegex(pattern, flags)
        @test re.regular
        d = C.automaton(re)
        @test d !== nothing
        for s in texts
            want = C.exec_slots(re, codeunits(s), 0, false, nothing)[3]
            got, decided = C.is_match(d, codeunits(s))
            # A text beyond ASCII may still be decided before its first such unit (a|, which accepts at once).
            isascii(s) && @test decided
            decided && @test got == want
            got16, decided16 = C.is_match(d, transcode(UInt16, s))
            decided16 && @test got16 == want
        end
    end
    @test !EcmaRegex("(a)\\1").regular
    @test !EcmaRegex("a(?=b)").regular
end
