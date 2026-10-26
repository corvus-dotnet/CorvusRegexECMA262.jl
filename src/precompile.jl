# A workload run while the package is precompiled, so that the code it compiles is kept in the package's cache: a
# program's first pattern and first match then run compiled code, not the compiler. Each search and each encoding is
# reached once.

if ccall(:jl_generating_output, Cint, ()) == 1
    let text = "The year 2026, the month 10; Ünïcödé text, 😀 and more letters after it. Sherlock Holmes."
        subjects = (text, Utf8Text(text), transcode(UInt16, text), Vector{UInt8}(text), SubString(text, 1))
        patterns = (("\\d+", ""), ("(?<y>\\d{4})\\D+(\\d+)", "u"), ("text|month", "i"), ("(?<=the )\\w+", "u"),
            ("(t|e)\\1", ""), ("\\p{L}+", "u"), ("[\\p{L}--[a-z]]+", "v"), ("^.*\$", "m"), ("\\bt\\w*\\b", "gi"),
            ("letters", ""), ("year|month|text|letters", ""), ("Sherlock|Holmes|Watson", "i"),
            ("year.{0,25}month|month.{0,25}year", ""), ("\\s[a-z]{0,12}ers\\s", ""), ("\\w+\\s+month", ""),
            ("\\d\\d:?\\d\\d", ""), (".*", "s"), ("[^\\n]*", ""), ("\\p{L}", "u"), ("[a-q][^u-z]{3}x", ""),
            ("(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\\.){3}", ""))
        for (pattern, flags) in patterns, u in ("", "u")
            flags = flags == "v" || occursin('u', flags) ? flags : flags * u
            re = EcmaRegex(pattern, flags)
            c = Captures(re)
            for s in subjects
                occursin(re, s)
                count(re, s)
                match(re, s)
                findall(re, s)
                for _ in eachmatch!(c, s)
                end
                match!(c, s)
                ecmasplit(s, re)
            end
            replace(text, re => "<\$&>")
            split(text, re)
            collect(eachmatch(re, text))
        end
    end
end
