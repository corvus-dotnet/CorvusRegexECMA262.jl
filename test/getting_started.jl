# The examples of the getting-started page the documentation site publishes (docs/getting-started.md), each block of
# Julia run in a module of its own, so that the page shows only code that works.

@testset "getting started" begin
    page = read(joinpath(@__DIR__, "..", "docs", "getting-started.md"), String)
    blocks = [m.captures[1] for m in eachmatch(r"(?ms)^```julia\n(.*?)^```$", page)]
    @test length(blocks) >= 5
    for (n, block) in enumerate(blocks)
        @testset "block $n" begin
            sandbox = Module(Symbol("GettingStarted", n))
            @test (Core.eval(sandbox, Meta.parseall(block)); true)
        end
    end
end
