using Test
using CodeTree

@testset "CodeTree" begin
    @test isdefined(CodeTree, :CREATE_CODE_TABLE)
    @test isdefined(CodeTree, :CREATE_REFS_TABLE)
    @test occursin("CREATE TABLE IF NOT EXISTS code",  CodeTree.CREATE_CODE_TABLE)
    @test occursin("CREATE TABLE IF NOT EXISTS refs",  CodeTree.CREATE_REFS_TABLE)
end
