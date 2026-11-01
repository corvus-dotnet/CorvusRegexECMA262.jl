# The grammar-only reader, isvalid_pattern: the grammar's answer, without the limits of size (validate.rs of the Rust
# crate, ValidatorTest of the Java engine, validate_test.go of the Go engine).

compiles(pattern, flags; kwargs...) = tryparse(EcmaRegex, pattern, flags; kwargs...) !== nothing

@testset "the grammar-only reader applies no limit of size" begin
    deep(n, open, close) = open^n * "a" * close^n
    names = join("(?<n$n>a)" for n in 0:4999)
    shared = join(fill("(?<n>a)", 5000), "|")
    twice = "(?<n>a)"^5000
    for (pattern, flags, valid) in (("a"^(C.MAX_PATTERN_LENGTH + 1), "u", true),
                                    ("a"^(C.MAX_PATTERN_LENGTH + 1) * "(", "u", false),
                                    (deep(C.MAX_NESTING + 1, "(?:", ")"), "u", true),
                                    (deep(200_000, "(?:", ")"), "", true),
                                    (deep(200_000, "(?:", ")") * ")", "u", false),
                                    (deep(200_000, "(?=", ")"), "", true),
                                    (deep(200_000, "[", "]"), "v", true),
                                    (deep(200_000, "[^", "]"), "v", true),
                                    (deep(200_000, "[", "]") * "]", "v", false),
                                    (names * "\\k<n4999>", "u", true),
                                    (names * "\\k<m>", "u", false),
                                    (shared, "u", true),
                                    (twice, "u", false),
                                    # A string that is not UTF-8 is not a pattern.
                                    (String(UInt8[0x61, 0xff]), "", false))
        @test (first(pattern, 40), flags, C.isvalid_pattern(pattern, flags)) == (first(pattern, 40), flags, valid)
        valid || @test !compiles(pattern, flags)
    end
    @test !C.isvalid_pattern("a", "uv")
    @test !C.isvalid_pattern("a", "uu")
    @test !C.isvalid_pattern("a", "x")
    @test !C.isvalid_pattern("a", "d"; edition=:es2020)
    @test_throws ArgumentError C.isvalid_pattern("a", "u"; edition=:es2015)
    @test_throws ArgumentError C.isvalid_pattern("a", "u"; unicode_version=14)
end

@testset "the grammar-only reader agrees with the parser" begin
    patterns = ["(?i:a)", "(?<a>x)|(?<a>y)", "(?<a>x)(?<a>y)", "((?<a>x)|(?<a>y))(?<a>z)", "(?<a>x)|((?<a>y)|(?<a>z))",
        "\\k<a>(?<a>x)", "\\k<a>", "\\k", "(?<a>x)\\k", "\\1(x)", "\\2(x)", "\\8", "\\08", "[\\8]", "\\c", "[\\c_]",
        "\\u{10FFFF}", "\\u{110000}", "😀", "(?<\\u{1d4d0}>x)", "(?<𝓐>x)", "(?<\\ud835\\udcd0>x)",
        "\\p{Script=Greek}", "\\p{sc=Yezi}", "\\p{Script=Sidetic}", "\\P{RGI_Emoji}", "\\p{RGI_Emoji}",
        "[^\\p{RGI_Emoji}]", "\\p{L}", "\\p{Lu}", "\\p{Letter}", "\\p{ASCII}", "\\p{Any}", "\\p{Assigned}", "\\p{gc=LC}",
        "\\p{scx=Hrkt}", "\\p{é}", "\\p{", "\\p{}", "a{2,1}", "a{99999999999999999999,1}", "a{1,99999999999999999999}",
        "a{,1}", "x{", "{1}", "]", "}", "[a-]", "[\\d-a]", "[a-\\d]", "[z-a]", "[\\b-\\n]", "(?=a)*", "(?<=a)*",
        "(?!a){2}", "[[a]&&[b]]", "[a&&b&&c]", "[a--b--c]", "[a&&b--c]", "[a-z&&b]", "[\\q{abc}]", "[^\\q{abc}]",
        "[^\\q{a|b}]", "[^[\\q{ab}]]", "[^[^\\q{ab}]]", "[[\\q{ab}]&&a]", "[^[\\q{ab}]&&a]", "[^a--\\q{ab}]",
        "[\\q{ab}--a]", "[^\\q{ab}--a]", "[a&&]", "[&&a]", "[a!!b]", "[\\!]", "[(]", "[a-[b]]", "[\\q{a", "(?i-i:a)",
        "(?-:a)", "(?ii:a)", "(?x:a)", "(?i", "(?<", "(?<a", "(?<a>", "(?<=", "a|*", "\\", "[\\", "(", ")", "a)",
        "\\b+", "^*", "\$+", "\\B{2}", "\\xg", "\\x4", "\\-", "[\\-]", "\\/", "\\a", "\\_", "😀{2}", "[😀-😁]",
        "[😁-😀]", "\\p{General_Category=Lu}", "\\p{Script_Extensions=Latin}", "\\p{ID_Compat_Math_Start}",
        "\\p{Lowercase}", "\\p{Script=Katakana_Or_Hiragana}", "\\p{Basic_Emoji}", "\\P{Basic_Emoji}",
        # The disjunction asked is the innermost still open around the earlier group, wherever the groups close.
        "(?:(?<a>x))|(?<a>y)", "(?:(?<a>x)|b)(?<a>y)", "((?<a>x)|(?:(?<a>y)))", "(?:(?<a>x)|(?:c))(?:d|(?<a>y))",
        "(?:(?:(?<a>x)))|(?:(?:(?<a>y)))|(?<a>z)", "(?:(?:(?<a>x))|(?<b>y))(?<a>z)", "(?:(?<a>x)|(?:(?<a>y)|(?<a>z)))",
        "(?:(?:(?<a>x)|y)|(?<a>z))", "(?:(?:(?<a>x)|y)(?<a>z))", "(?<a>x)|(?:(?:(?<b>y))(?<a>z))",
        "(?:(?:(?<a>x))(?:(?<b>y)))|(?<a>z)(?<b>w)", "(?:(?<a>x))(?:(?<b>y)|(?<a>z))"]
    for p in patterns, flags in ("", "u", "v", "i", "iu"), edition in (:current, :es2020), version in (:default, 13, 18)
        want = compiles(p, flags; edition=edition, unicode_version=version)
        @test (p, flags, edition, version, C.isvalid_pattern(p, flags; edition=edition, unicode_version=version)) ==
              (p, flags, edition, version, want)
    end
end

# Each named group keeps the disjunction and the alternative it lies in, not a copy of the path to it, so nested named
# groups take memory in proportion to their number, not to its square. A name kept deep inside one alternative and used
# again in the next walks out of the closed groups to the disjunction around both, and the walk is shortened as it goes,
# so each name does not walk the whole depth again.
@testset "named groups are read in memory and time in proportion to the pattern" begin
    nested = join("(?<g$k>" for k in 0:99_999) * "a" * ")"^100_000
    reused = "(?:"^50_000 * join("(?<n$k>a)" for k in 0:19_999) * ")"^50_000 * "|" * join("(?<n$k>b)" for k in 0:19_999)
    for (pattern, valid) in ((nested, true), (reused, true), (reused * "(?<n0>c)", false))
        C.isvalid_pattern("a", "u")
        stats = @timed C.isvalid_pattern(pattern, "u")
        @test stats.value == valid
        @test stats.bytes < 64 * ncodeunits(pattern)
        @test stats.time < 10
    end
end
