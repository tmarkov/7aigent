using Test
using CodeTree
using DataFrames
using DataFramesMeta

# Phase 0 smoke test: the module loads without error.
@testset "CodeTree module loads" begin
    @test nameof(CodeTree) === :CodeTree
end
