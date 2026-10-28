# The edition of the grammar and the version of Unicode (tests/editions.rs of the Rust crate): ECMAScript 2020 refuses
# what later editions added and nothing else, and each version of Unicode has its own scripts and case folding, in the
# matcher as in the parser.

# U+10570 and U+10597 are a capital and a small letter of Vithkuqi, a script of Unicode 14. U+A7C0 and U+A7C1 are the
# capital and the small Old Polish O, also of Unicode 14.
const VITHKUQI_PAIR = "\U10570\U10597"
const VITHKUQI_SMALL = "\U10597"
const OLD_POLISH_PAIR = "Ꟁꟁ"

under(pattern, flags, version) = EcmaRegex(pattern, flags; unicode_version=version)
built(pattern, flags, edition, version) = C.try_compile(pattern, flags; edition, unicode_version=version)

@testset "editions" begin
    @testset "the defaults are today's grammar and V8's Unicode" begin
        re = EcmaRegex("a")
        @test C.edition(re) === :current
        @test C.unicode_version(re) == 17
        @test C.match_timeout(EcmaRegex("a"; edition=:es2020)) == C.match_timeout(re)
    end

    @testset "a version is resolved when the pattern is compiled" begin
        for (asked, resolved) in ((:default, 17), (13, 13), (17, 17), (18, 18), (:latest, 18))
            @test C.unicode_version(under("a", "", asked)) == resolved
        end
        @test_throws ArgumentError EcmaRegex("a"; unicode_version=14)
        @test_throws ArgumentError EcmaRegex("a"; edition=:es2015)
    end

    @testset "each version has its own scripts" begin
        for (pattern, version, valid) in (("\\p{Script=Vithkuqi}", 13, false), ("\\p{Script=Vithkuqi}", :default, true),
                                         ("\\p{Script=Yezidi}", 13, true), ("\\p{Script=Jurchen}", :default, false),
                                         ("\\p{scx=Jurc}", 18, true), ("\\p{Script=Jurchen}", :latest, true))
            @test C.isvalid_pattern(pattern, "u"; unicode_version=version) == valid
            @test (built(pattern, "u", :current, version)[1] !== nothing) == valid
        end
    end

    @testset "a property set is its version's however the cache was filled" begin
        # The same expression under two versions, in both orders: the cache of property sets is one for each version.
        for _ in 1:2
            @test occursin(under("^\\p{Ll}\$", "u", 17), VITHKUQI_SMALL)
            @test !occursin(under("^\\p{Ll}\$", "u", 13), VITHKUQI_SMALL)
        end
    end

    @testset "a literal in a case-insensitive pattern folds as its version folds" begin
        @test occursin(under("\\u{10570}", "iu", 17), VITHKUQI_SMALL)
        @test !occursin(under("\\u{10570}", "iu", 13), VITHKUQI_SMALL)
        @test occursin(under("Ꟁ", "i", 17), "ꟁ")
        @test !occursin(under("Ꟁ", "i", 13), "ꟁ")
    end

    @testset "a backreference in a case-insensitive pattern folds as its version folds" begin
        for (flags, text) in (("iu", VITHKUQI_PAIR), ("i", OLD_POLISH_PAIR))
            first = string(text[1])
            twice = first^2
            t16 = transcode(UInt16, text)
            for pattern in ("(.)\\1", "(?<=\\1(.))", "(?:x|(.))+\\1\$")
                for version in (17, 18)
                    re = under(pattern, flags, version)
                    @test occursin(re, text)
                    @test occursin(re, t16)
                end
                re = under(pattern, flags, 13)
                @test !occursin(re, text)
                @test !occursin(re, t16)
                @test occursin(re, twice)
                # The program that records every group folds as the one that finds the match.
                @test match(re, twice) !== nothing
                @test match(re, text) === nothing
            end
        end
    end

    @testset "the grammar of 2020 refuses what later editions added" begin
        for (pattern, flags) in (("(?i:a)", ""), ("(?-i:a)", "i"), ("(?s:.)", "u"), ("(?<a>x)|(?<a>y)", ""),
                                 ("(?<a>x)|(?<a>y)", "u"), ("\\p{Script=Yezidi}", "u"), ("\\p{sc=Vith}", "u"),
                                 ("\\p{Script_Extensions=Toto}", "u"))
            re, err = built(pattern, flags, :es2020, :latest)
            @test re === nothing && err isa C.InvalidPatternError
            @test built(pattern, flags, :current, :latest)[1] !== nothing
        end
    end

    @testset "the grammar of 2020 accepts what it had" begin
        for (pattern, flags) in (("\\p{Script=Greek}", "u"), ("\\p{L}\\p{gc=Lu}\\p{Lowercase}", "u"),
                                 ("\\P{scx=Latn}", "iu"), ("\\p{Script=Yezidi}", ""), ("(?<a>x)(?<b>y)\\k<a>", "u"),
                                 ("(?<=a)(?<!b)", "s"), ("(?:i)", ""))
            re, err = built(pattern, flags, :es2020, 13)
            @test re !== nothing
            @test err === nothing
        end
    end

    @testset "the grammar of 2020 has no d or v flag" begin
        for flags in ("d", "v")
            re, err = built("a", flags, :es2020, :default)
            @test re === nothing && err isa C.FlagsError
            @test !C.isvalid_pattern("a", flags; edition=:es2020)
            @test built("a", flags, :current, :default)[1] !== nothing
        end
    end

    @testset "try_compile takes a match timeout and throws nothing for the pattern" begin
        re, err = C.try_compile("a+", "u"; match_timeout=0.05)
        @test err === nothing && C.match_timeout(re) == 0.05
        re, err = C.try_compile("(", "u"; match_timeout=1)
        @test re === nothing && err isa C.InvalidPatternError
        @test C.try_compile("a", "x")[2] isa C.FlagsError
        @test C.try_compile(String(UInt8[0x61, 0xff]))[2] isa C.EncodingError
        @test tryparse(EcmaRegex, "(") === nothing
        @test tryparse(EcmaRegex, "a+", "u"; edition=:es2020) isa EcmaRegex
    end
end
