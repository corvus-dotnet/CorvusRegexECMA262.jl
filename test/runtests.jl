using CorvusRegexEcma262
using Test

const C = CorvusRegexEcma262

@testset "flags" begin
    f = C.parse_flags("ysvmigd")
    @test string(f) == "dgimsvy"
    for bad in ("x", "gg", "uv")
        @test_throws C.FlagsError C.parse_flags(bad)
    end
end

@testset "compile errors" begin
    @test_throws C.InvalidPatternError EcmaRegex("a{2,1}")
    @test_throws C.FlagsError EcmaRegex("\\p{Lu}", "q")
    @test_throws C.EncodingError EcmaRegex(String(UInt8[0x61, 0xff, 0x62]))
    @test C.isvalid_pattern("\\p{Lu}", "u")
    @test !C.isvalid_pattern("\\p{Lu", "u")
    @test C.isvalid_pattern("\\p{Lu", "")
    @test_throws C.TooLargeError EcmaRegex("("^1001 * ")"^1001)
end

@testset "match and find" begin
    re = ecma"(?<year>\d{4})-(?<month>\d{2})"u
    @test occursin(re, "on 2026-10-25")
    @test !occursin(re, "on 26-10")
    @test findfirst(re, "on 2026-10-25") == 4:10
    m = match(re, "on 2026-10-25")
    @test m.match == "2026-10"
    @test m.offset == 4
    @test m.captures == ["2026", "10"]
    @test m.offsets == [4, 9]
    @test m[:month] == "10"
    @test m["year"] == "2026"
    @test m[2] == "10"
    @test keys(m) == ["year", "month"]
    @test C.group_names(re) == ["year", "month"]
    @test C.group_index(re, "month") == [2]
    @test sprint(show, re) == "ecma\"(?<year>\\\\d{4})-(?<month>\\\\d{2})\"u"
    @test match(re, "on 2026-10-25", 5) === nothing
    @test findnext(ecma"\d"u, "a1b2", 3) == 4:4
end

@testset "a group that did not take part" begin
    m = match(ecma"(a)|(b)", "b")
    @test m.captures == [nothing, "b"]
    @test m.offsets == [0, 1]
end

@testset "a global search moves on past an empty match" begin
    re = ecma"a*"u
    @test findall(re, "baa😀") == [1:0, 2:3, 4:3, 8:7]
    @test [m.offset for m in eachmatch(re, "baa😀")] == [1, 2, 4, 8]
    @test count(ecma"\w+", "hello big world") == 3
    # Without the u flag a code unit at a time: between the halves of the pair, and after it.
    @test length(findall(ecma"", transcode(UInt16, "😀"))) == 3
    @test length(findall(ecma""u, transcode(UInt16, "😀"))) == 2
end

@testset "replace" begin
    re = ecma"(?<year>\d{4})-(?<month>\d{2})"u
    @test replace("2026-10 and 2027-11", re => "\$<month>/\$<year>"; count=1) == "10/2026 and 2027-11"
    @test replace("2026-10 and 2027-11", re => "[\$&|\$1|\$\$|\$`|\$']") ==
          "[2026-10|2026|\$|| and 2027-11] and [2027-11|2027|\$|2026-10 and |]"
    @test replace("foo", ecma"o" => "0") == "f00"
    # Without a named group $< is itself.
    @test replace("o", ecma"o" => "\$<x>") == "\$<x>"
    @test replace("abc", ecma"x" => "y") == "abc"
    @test replace(transcode(UInt16, "abc"), ecma"b" => transcode(UInt16, "[\$&]")) == transcode(UInt16, "a[b]c")
    @test replace(Vector{UInt8}("abcb"), ecma"b+" => Vector{UInt8}("[\$&]")) == Vector{UInt8}("a[b]c[b]")
end

@testset "split" begin
    @test split("a1b22c", ecma"\d+") == ["a", "b", "c"]
    @test split("abc", ecma"") == split("abc", r"")
    @test split(",a,", ecma",") == split(",a,", r",")
    @test split("a,b,,c", ecma","; keepempty=false) == ["a", "b", "c"]
    @test split("a,b,c", ecma","; limit=2) == ["a", "b,c"]
    re = ecma"(-)|(\+)"
    @test ecmasplit("a-b+c", re) == ["a", "-", nothing, "b", nothing, "+", "c"]
    @test length(ecmasplit("a-b+c", re; limit=3)) == 3
    @test isempty(ecmasplit("", ecma"x*"))
    @test ecmasplit("", ecma"x") == [""]
end

@testset "text that is not UTF-8 is refused" begin
    re = ecma"a"u
    @test_throws C.EncodingError occursin(re, "a\xff")
    @test_throws C.EncodingError match(re, "a\xff")
    @test_throws C.EncodingError occursin(re, UInt8[0xC0, 0x80])
    @test_throws C.EncodingError Utf8Text(UInt8[0xED, 0xA0, 0x80])
    @test_throws C.EncodingError Utf8Text("a\xff")
end

@testset "UTF-16" begin
    u = transcode(UInt16, "x😀y")
    @test occursin(ecma"^.y", u[3:end])          # a lone low surrogate is a character without the u flag
    @test occursin(ecma"x.y"u, u)                # the dot takes a pair with the u flag
    @test !occursin(ecma"x.y", u)                # and one unit without it
    pieces = ecmasplit(u, ecma"😀"u)
    @test length(pieces) == 2 && pieces[1] == transcode(UInt16, "x") && pieces[2] == transcode(UInt16, "y")
    @test findfirst(ecma"."u, transcode(UInt16, "😀")) == 1:2
    @test findfirst(ecma".", transcode(UInt16, "😀")) == 1:1
end

@testset "a half character is written as U+FFFD" begin
    # Without the u flag \ude00 is a code unit, the second half of 😀 (F0 9F 98 80 is D83D DE00).
    @test replace("a😀b", ecma"\ude00" => "-") == "a�-b"
    @test match(ecma"\ude00", "a😀b").match == "�"
end

@testset "timeout" begin
    re = EcmaRegex("(?:a?){1000}a{1000}"; match_timeout=0.001)
    @test C.match_timeout(re) == 0.001
    text = "a"^999
    try
        occursin(re, text)
    catch e
        @test e isa C.MatchTimeoutError || e isa C.MatchMemoryError
    end
    @test C.match_timeout(ecma"a") === nothing
    C.set_default_match_timeout!(5)
    @test C.match_timeout(EcmaRegex("a")) == 5.0
    C.set_default_match_timeout!(nothing)
    @test C.match_timeout(EcmaRegex("a")) === nothing
end

@testset "linear time without backreferences" begin
    @test !occursin(EcmaRegex("^(a+)+\$"), "a"^5000 * "b")
    @test !occursin(EcmaRegex("^(?:a|aa)*\$"), "a"^5000 * "b")
end

function search_all(c::Captures, text::Utf8Text)
    n = 0
    i = 1
    while match!(c, text, i)
        n += 1
        r = capture_range(c)
        i = last(r) + 1
    end
    return n
end

@testset "a match into Captures allocates nothing" begin
    re = ecma"(?<k>\w+)=(?<v>\d+)"u
    c = Captures(re)
    text = Utf8Text("x a=1 b=22")
    @test match!(c, text)
    @test capture_range(c) == 3:5
    @test capture_range(c, 2) == 5:5
    @test search_all(c, text) == 2
    for _ in 1:3
        search_all(c, text)
    end
    @test minimum(@allocated(search_all(c, text)) for _ in 1:5) == 0
    @test !match!(c, text, 12)
    @test capture_range(c) === nothing
end

@testset "byte vectors" begin
    re = ecma"b+"
    @test occursin(re, Vector{UInt8}("abbc"))
    @test findfirst(re, Vector{UInt8}("abbc")) == 2:3
    @test match(re, Vector{UInt8}("abbc")).match == Vector{UInt8}("bb")
end
include("dfa.jl")
