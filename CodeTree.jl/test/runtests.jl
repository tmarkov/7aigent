using Test
using CodeTree
using DataFrames
using DataFramesMeta

# Phase 0 smoke test: the module loads without error.
@testset "CodeTree module loads" begin
    @test nameof(CodeTree) === :CodeTree
end

# ---------------------------------------------------------------------------
# Phase 1 — Read-Only DataFrames and Core Structs
# R1, R2, R3, R4
# ---------------------------------------------------------------------------

# Helper: build a minimal CodeTree and CodeSymbols from DataFrames for use
# in tests that don't require a full load() call.
function minimal_code_df()
    DataFrame(
        id            = ["root", "root/file.jl", "root/file.jl:foo",
                         "root/file.jl:foo\$2", "root/file.jl:foo\$3"],
        parent        = [missing, "root", "root/file.jl",
                         "root/file.jl", "root/file.jl"],
        depth         = [0, 1, 2, 2, 2],
        sibling_order = [0, 0, 0, 1, 2],
        kind          = ["codebase", "file", "function", "function", "function"],
        name          = ["root", "file.jl", "foo", "foo", "foo"],
        qname         = [missing, "file.jl", "file.jl.foo",
                         "file.jl.foo\$2", "file.jl.foo\$3"],
        language      = [missing, "julia", "julia", "julia", "julia"],
        summary       = [missing, missing, "First foo.", missing, missing],
        source        = [missing, missing, "function foo() end",
                         "function foo(x) x end", "function foo(x,y) x+y end"],
        signature     = [missing, missing, "function foo()",
                         "function foo(x)", "function foo(x, y)"],
        file          = [missing, "file.jl", "file.jl", "file.jl", "file.jl"],
        line_start    = [missing, 1, 1, 2, 3],
        line_end      = [missing, 3, 1, 2, 3],
        n_lines       = [missing, 3, 1, 1, 1],
        n_children    = [0, 3, 0, 0, 0],
    )
end

function minimal_symbols_df()
    DataFrame(
        node_id = ["root/file.jl:foo", "root/file.jl:foo", "root/file.jl:foo\$2"],
        symbol  = ["bar", "baz", "bar"],
        kind    = ["call", "var_ref", "call"],
    )
end

@testset "R2: db.symbols has the required columns with correct element types" begin
    sym = CodeTree.CodeSymbols(minimal_symbols_df())
    cols = propertynames(sym)
    @test :node_id ∈ cols
    @test :symbol  ∈ cols
    @test :kind    ∈ cols
    # node_id and symbol are String columns; kind is String
    @test eltype(sym.node_id) == String
    @test eltype(sym.symbol)  == String
    @test eltype(sym.kind)    == String
end

@testset "R3: filter operations work on CodeTree (db.code)" begin
    ct = CodeTree.CodeTree(minimal_code_df())
    fns = filter(r -> r.kind == "function", ct)
    @test nrow(fns) == 3
    # @subset from DataFramesMeta must also work
    fns2 = @subset(ct, :kind .== "function")
    @test nrow(fns2) == 3
end

@testset "R3: filter operations work on CodeSymbols (db.symbols)" begin
    sym = CodeTree.CodeSymbols(minimal_symbols_df())
    calls = filter(r -> r.kind == "call", sym)
    @test nrow(calls) == 2
end

@testset "R3: join between CodeTree and CodeSymbols works" begin
    ct  = CodeTree.CodeTree(minimal_code_df())
    sym = CodeTree.CodeSymbols(minimal_symbols_df())
    # Both tables have a :kind column; makeunique disambiguates (kind = symbol kind,
    # kind_1 = node kind). This mirrors real usage of db.symbols ⋈ db.code.
    joined = innerjoin(sym, ct, on = :node_id => :id, makeunique = true)
    @test nrow(joined) == 3
    @test :name ∈ propertynames(joined)
end

@testset "R4: setindex! on CodeTree raises an error mentioning update_source" begin
    ct = CodeTree.CodeTree(minimal_code_df())
    err = @test_throws Exception (ct[1, :name] = "changed")
    @test occursin("update_source", lowercase(sprint(showerror, err.value)))
end

@testset "R4: setindex! on CodeSymbols raises an informative error" begin
    sym = CodeTree.CodeSymbols(minimal_symbols_df())
    err = @test_throws Exception (sym[1, :symbol] = "changed")
    @test occursin("update_source", lowercase(sprint(showerror, err.value)))
end

@testset "R1: first duplicate sibling keeps base id; second gets \$2; third gets \$3" begin
    # The ordinal_suffix_ids helper takes a list of (name, line_start) pairs
    # (all under the same parent) and returns the id suffix for each.
    assign = CodeTree.assign_ordinal_ids
    # Two siblings named "process"
    result = assign(["process", "process"], [153, 160])
    @test result[1] == "process"
    @test result[2] == "process\$2"
    # Three siblings named "foo"
    result3 = assign(["foo", "foo", "foo"], [1, 2, 3])
    @test result3[1] == "foo"
    @test result3[2] == "foo\$2"
    @test result3[3] == "foo\$3"
    # No duplicates → no suffix
    result_unique = assign(["alpha", "beta", "gamma"], [1, 2, 3])
    @test result_unique == ["alpha", "beta", "gamma"]
end

