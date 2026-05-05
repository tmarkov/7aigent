using Test
using CodeTree
using DataFrames
using DataFramesMeta
using SQLite
using DBInterface

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

# ---------------------------------------------------------------------------
# Phase 2 — Language Config
# R9, R9a
# ---------------------------------------------------------------------------

# Shared test config used throughout the test suite (Phase 2 onwards).
# Constructed once here; imported by later tests via `TEST_CONFIG`.
TEST_CONFIG = CodeTree.LanguageConfig(Dict(
    "cpp" => CodeTree.LanguageEntry(
        # R9: mapping of C++ AST node type names to (class, kind)
        Dict(
            "function_definition" => CodeTree.NodeMapping(:landmark, "function"),
            "class_specifier"     => CodeTree.NodeMapping(:landmark, "class"),
            "struct_specifier"    => CodeTree.NodeMapping(:landmark, "class"),
            "namespace_definition"=> CodeTree.NodeMapping(:landmark, "module"),
            "if_statement"        => CodeTree.NodeMapping(:detail, "conditional"),
            "while_statement"     => CodeTree.NodeMapping(:detail, "loop"),
            "for_statement"       => CodeTree.NodeMapping(:detail, "loop"),
            "do_statement"        => CodeTree.NodeMapping(:detail, "loop"),
            "try_statement"       => CodeTree.NodeMapping(:detail, "try"),
            "switch_statement"    => CodeTree.NodeMapping(:detail, "conditional"),
        ),
        # R9a: call patterns (tree-sitter query strings)
        ["(call_expression function: (identifier) @call)",
         "(call_expression function: (field_expression field: (field_identifier) @call))"],
        # R9a: definition patterns
        ["(declaration declarator: (identifier) @def)",
         "(init_declarator declarator: (identifier) @def)",
         "(parameter_declaration declarator: (identifier) @def)",
         "(array_declarator declarator: (identifier) @def)",
         "(pointer_declarator declarator: (identifier) @def)",
         "(for_range_loop left: (identifier) @def)"],
    ),
    "julia" => CodeTree.LanguageEntry(
        Dict(
            "function_definition" => CodeTree.NodeMapping(:landmark, "function"),
            "short_function_definition" => CodeTree.NodeMapping(:landmark, "function"),
            "macro_definition"    => CodeTree.NodeMapping(:landmark, "function"),
            "struct_definition"   => CodeTree.NodeMapping(:landmark, "class"),
            "abstract_definition" => CodeTree.NodeMapping(:landmark, "type"),
            "module_definition"   => CodeTree.NodeMapping(:landmark, "module"),
            "if_statement"        => CodeTree.NodeMapping(:detail, "conditional"),
            "elseif_clause"       => CodeTree.NodeMapping(:detail, "conditional"),
            "for_statement"       => CodeTree.NodeMapping(:detail, "loop"),
            "while_statement"     => CodeTree.NodeMapping(:detail, "loop"),
            "try_statement"       => CodeTree.NodeMapping(:detail, "try"),
            "do_clause"           => CodeTree.NodeMapping(:detail, "with"),
        ),
        ["(call_expression (identifier) @call)",
         "(call_expression (field_expression field: (identifier) @call))"],
        ["(assignment left: (identifier) @def)",
         "(local_declaration (identifier) @def)",
         "(for_binding left: (identifier) @def)",
         "(parameter_list (identifier) @def)",
         "(typed_parameter . (identifier) @def)"],
    ),
    "markdown" => CodeTree.LanguageEntry(
        # R13: Markdown uses Julia stdlib type names, config-driven
        Dict(
            "Header"    => CodeTree.NodeMapping(:landmark, "function"),
            "Paragraph" => CodeTree.NodeMapping(:detail, "chunk"),
            "Code"      => CodeTree.NodeMapping(:detail, "chunk"),
        ),
        String[],   # no call patterns for Markdown
        String[],   # no definition patterns for Markdown
    ),
), Dict(
    # R7: extension → language name mapping
    ".cpp"  => "cpp",
    ".cc"   => "cpp",
    ".cxx"  => "cpp",
    ".hpp"  => "cpp",
    ".h"    => "cpp",
    ".jl"   => "julia",
    ".md"   => "markdown",
))

@testset "R9: config maps AST node type names to (class, kind) per language" begin
    classify = CodeTree.classify_node

    # C++ function_definition → landmark, function
    m = classify(TEST_CONFIG, "cpp", "function_definition")
    @test !isnothing(m)
    @test m.class == :landmark
    @test m.kind  == "function"

    # C++ if_statement → detail, conditional
    m2 = classify(TEST_CONFIG, "cpp", "if_statement")
    @test !isnothing(m2)
    @test m2.class == :detail
    @test m2.kind  == "conditional"

    # Unknown AST type → nothing (not in config)
    @test isnothing(classify(TEST_CONFIG, "cpp", "translation_unit"))

    # Unknown language → nothing
    @test isnothing(classify(TEST_CONFIG, "fortran", "program"))
end

@testset "R9: Julia config maps struct and module node types correctly" begin
    classify = CodeTree.classify_node

    m = classify(TEST_CONFIG, "julia", "struct_definition")
    @test !isnothing(m)
    @test m.class == :landmark
    @test m.kind  == "class"

    m2 = classify(TEST_CONFIG, "julia", "for_statement")
    @test !isnothing(m2)
    @test m2.class == :detail
    @test m2.kind  == "loop"
end

@testset "R9: Markdown config maps landmark/detail to Julia stdlib type names" begin
    m = CodeTree.classify_node(TEST_CONFIG, "markdown", "Header")
    @test !isnothing(m)
    @test m.class == :landmark
end

@testset "R9a: each language entry has non-empty call_patterns and definition_patterns" begin
    cpp_entry  = TEST_CONFIG.languages["cpp"]
    julia_entry = TEST_CONFIG.languages["julia"]

    @test !isempty(cpp_entry.call_patterns)
    @test !isempty(cpp_entry.definition_patterns)
    @test !isempty(julia_entry.call_patterns)
    @test !isempty(julia_entry.definition_patterns)

    # Markdown may have empty patterns (no code to parse)
    md_entry = TEST_CONFIG.languages["markdown"]
    @test isa(md_entry.call_patterns, Vector{String})
    @test isa(md_entry.definition_patterns, Vector{String})
end

@testset "R9a: call_patterns and definition_patterns are Vectors of Strings" begin
    for (lang, entry) in TEST_CONFIG.languages
        @test isa(entry.call_patterns,       Vector{String})
        @test isa(entry.definition_patterns, Vector{String})
    end
end

# ---------------------------------------------------------------------------
# Phase 3 — File Discovery
# R5, R7
# (R6 structural nodes require the tree builder and are tested in Phase 4)
# ---------------------------------------------------------------------------

const TEST_CODEBASE = joinpath(@__DIR__, "test_codebase")

# All files expected to be discovered in the test codebase (relative paths)
const EXPECTED_FILES = Set([
    ".gitignore",
    "README.md",
    "data/config.toml",
    "docs/api.md",
    "docs/overview.md",
    "julia/core.jl",
    "julia/utils.jl",
    "src/algorithms.cpp",
    "src/algorithms.hpp",
    "src/main.cpp",
])

@testset "R5: discover_files returns all tracked and untracked-non-ignored files" begin
    paths = CodeTree.discover_files(TEST_CODEBASE)
    path_set = Set(paths)
    @test path_set == EXPECTED_FILES
end

@testset "R5: gitignored files are absent from discover_files results" begin
    # Create a temporary .o file inside the test_codebase tree; it matches *.o
    # in the .gitignore and must not appear in the results.
    tmp_obj = joinpath(TEST_CODEBASE, "src", "tmp_test_artifact.o")
    write(tmp_obj, "fake object file")
    try
        paths = CodeTree.discover_files(TEST_CODEBASE)
        @test "src/tmp_test_artifact.o" ∉ Set(paths)
    finally
        rm(tmp_obj; force=true)
    end
end

@testset "R7: language_for_file maps known extensions to language names" begin
    lff = CodeTree.language_for_file
    @test lff(TEST_CONFIG, "algorithms.cpp")  == "cpp"
    @test lff(TEST_CONFIG, "algorithms.hpp")  == "cpp"
    @test lff(TEST_CONFIG, "main.cpp")        == "cpp"
    @test lff(TEST_CONFIG, "core.jl")         == "julia"
    @test lff(TEST_CONFIG, "api.md")          == "markdown"
    @test lff(TEST_CONFIG, "README.md")       == "markdown"
end

@testset "R7: language_for_file returns missing for unmapped extensions (R8 case)" begin
    @test ismissing(CodeTree.language_for_file(TEST_CONFIG, "config.toml"))
    @test ismissing(CodeTree.language_for_file(TEST_CONFIG, "Makefile"))
    @test ismissing(CodeTree.language_for_file(TEST_CONFIG, ".gitignore"))
end

# ---------------------------------------------------------------------------
# Phase 4 — Tree Builder, Structural Nodes, Spanning
# R6, R8, R10, R11, R12, R14, R14b, R14c, R15, R16
# ---------------------------------------------------------------------------
# Load the test codebase once; all Phase 4+ tests use this DB.
const _DB = Ref{Any}(nothing)

@testset "Phase 4 setup: load() completes without error" begin
    _DB[] = CodeTree.load(TEST_CODEBASE, TEST_CONFIG)
    @test _DB[] isa CodeTree.CodeTreeDB
end

# Accessor used in all subsequent tests
_db() = _DB[]::CodeTree.CodeTreeDB

@testset "R6: exactly one codebase root node" begin
    roots = filter(r -> r.kind == "codebase", _db().code)
    @test nrow(roots) == 1
end

@testset "R6: one module node per source-containing subdirectory" begin
    mods = filter(r -> r.kind == "module", _db().code)
    mod_names = Set(mods.name)
    @test "src"   ∈ mod_names
    @test "julia" ∈ mod_names
    @test "docs"  ∈ mod_names
    @test "data"  ∈ mod_names
end

@testset "R6: one file node per discovered file" begin
    files = filter(r -> r.kind == "file", _db().code)
    fnames = Set(files.name)
    for expected in ["algorithms.cpp", "algorithms.hpp", "main.cpp",
                     "core.jl", "utils.jl", "api.md", "overview.md",
                     "README.md", "config.toml", ".gitignore"]
        @test expected ∈ fnames
    end
end

@testset "R7: language column set from file extension" begin
    code = _db().code
    cpp_row = only(filter(r -> r.kind == "file" && r.name == "algorithms.cpp", code))
    @test cpp_row.language == "cpp"
    jl_row  = only(filter(r -> r.kind == "file" && r.name == "core.jl", code))
    @test jl_row.language == "julia"
    md_row  = only(filter(r -> r.kind == "file" && r.name == "README.md", code))
    @test md_row.language == "markdown"
    toml_row = only(filter(r -> r.kind == "file" && r.name == "config.toml", code))
    @test ismissing(toml_row.language)
end

@testset "R8: unknown-language file is a single leaf node with no children" begin
    code = _db().code
    toml_node = only(filter(r -> isequal(r.file, "data/config.toml") && r.kind == "file", code))
    @test toml_node.n_children == 0
    @test !ismissing(toml_node.source)
end

@testset "R10: landmark nodes always appear in db.code" begin
    code = _db().code
    for fname in ["quick_sort", "merge_sort", "swap", "bucket_sort",
                  "timed_sort", "wacky"]
        rows = filter(r -> r.name == fname && isequal(r.file, "src/algorithms.cpp"), code)
        @test nrow(rows) >= 1
    end
    # R1: process appears twice — base name + $2
    all_ids = Set(code.id)
    @test any(id -> endswith(id, ":process"),    all_ids)
    @test any(id -> endswith(id, ":process\$2"), all_ids)
end

@testset "R11: detail nodes suppressed when parent spans < detail_threshold (30)" begin
    code = _db().code
    # quick_sort spans ~26 lines (< 30); its inner if/while must NOT appear
    qs = only(filter(r -> r.name == "quick_sort" && isequal(r.file, "src/algorithms.cpp"), code))
    qs_children = filter(r -> isequal(r.parent, qs.id), code)
    @test all(r -> r.kind == "chunk", eachrow(qs_children))
end

@testset "R11: detail nodes shown when parent spans >= detail_threshold (30)" begin
    code = _db().code
    # merge_sort spans ~36 lines (> 30); it must have at least one non-chunk child
    ms = only(filter(r -> r.name == "merge_sort" && isequal(r.file, "src/algorithms.cpp"), code))
    ms_children = filter(r -> isequal(r.parent, ms.id), code)
    @test any(r -> r.kind != "chunk", eachrow(ms_children))
end

@testset "R12: default detail_threshold is 30" begin
    # Calling load without explicit detail_threshold must yield the same R11 results
    db2 = CodeTree.load(TEST_CODEBASE, TEST_CONFIG)
    qs2 = only(filter(r -> r.name == "quick_sort" && isequal(r.file, "src/algorithms.cpp"), db2.code))
    qs2_children = filter(r -> isequal(r.parent, qs2.id), db2.code)
    @test all(r -> r.kind == "chunk", eachrow(qs2_children))
end

@testset "R14b: leading comment absorbed — quick_sort.line_start == 39" begin
    code = _db().code
    qs = only(filter(r -> r.name == "quick_sort" && isequal(r.file, "src/algorithms.cpp"), code))
    # R14b: two comment lines above quick_sort (lines 39–40) are adjacent → absorbed
    @test qs.line_start == 39
end

@testset "R14b: leading comment absorbed — merge_sort.line_start == 67" begin
    code = _db().code
    ms = only(filter(r -> r.name == "merge_sort" && isequal(r.file, "src/algorithms.cpp"), code))
    # R14b: three comment lines above merge_sort (lines 67–69) are adjacent → absorbed
    @test ms.line_start == 67
end

@testset "R14b negative: blank line prevents absorption — swap.line_start == 25" begin
    code = _db().code
    sw = only(filter(r -> r.name == "swap" && isequal(r.file, "src/algorithms.cpp"), code))
    # Blank line 24 separates the comment block (21–23) from swap's declaration → NOT absorbed
    @test sw.line_start == 25
end

@testset "R14c: no kind=chunk node consists entirely of blank lines" begin
    code = _db().code
    blank_chunks = filter(r -> r.kind == "chunk" &&
                               !ismissing(r.source) &&
                               all(isempty ∘ strip, split(r.source, '\n')), code)
    @test nrow(blank_chunks) == 0
end

@testset "R14: spanning invariant — every non-leaf node's children cover its full line range" begin
    code = _db().code
    # Only check nodes with a file (skip codebase/module structural nodes)
    nodes_with_lines = filter(r -> !ismissing(r.line_start) && r.n_children > 0, code)
    for parent_row in eachrow(nodes_with_lines)
        children = filter(r -> isequal(r.parent, parent_row.id) &&
                               !ismissing(r.line_start), code)
        nrow(children) == 0 && continue
        covered = Set{Int}()
        for c in eachrow(children)
            union!(covered, c.line_start:c.line_end)
        end
        expected = Set(parent_row.line_start:parent_row.line_end)
        @test covered == expected
    end
end

@testset "R15: chunk nodes fill every gap between compound children" begin
    code = _db().code
    chunks = filter(r -> r.kind == "chunk", code)
    # There must be at least one chunk in the database
    @test nrow(chunks) > 0
    # All chunk nodes are leaves (no children)
    @test all(r -> r.n_children == 0, eachrow(chunks))
end

@testset "R16: siblings are ordered by ascending line_start" begin
    code = _db().code
    # R16 applies to code nodes with line numbers; skip structural nodes
    # (codebase/module) whose children may have missing line_start.
    nodes_with_lines = filter(r -> !ismissing(r.parent) && !ismissing(r.line_start), code)
    for parent_id in unique(nodes_with_lines.parent)
        siblings = sort(
            filter(r -> isequal(r.parent, parent_id) && !ismissing(r.line_start), code),
            :sibling_order,
        )
        nrow(siblings) < 2 && continue
        @test issorted(siblings.line_start)
    end
end

# =============================================================================
# Phase 5 — Summary Extraction (R17, R18, R19, R20, R20a)
# =============================================================================

@testset "R17: sort_array (first overload) summary comes from its docstring" begin
    code = _db().code
    # The first sort_array does not end with $2
    nodes = filter(r -> isequal(r.name, "sort_array") && !endswith(r.id, "\$2"), code)
    @test nrow(nodes) == 1
    node = only(nodes)
    @test !ismissing(node.summary)
    @test occursin("quicksort", lowercase(something(node.summary, "")))
end

@testset "R17: DataStats struct summary comes from its docstring" begin
    code = _db().code
    nodes = filter(r -> isequal(r.name, "DataStats"), code)
    @test nrow(nodes) == 1
    @test occursin("statistics", lowercase(something(only(nodes).summary, "")))
end

@testset "R18: search_sorted summary comes from preceding comment (no docstring)" begin
    code = _db().code
    node = only(filter(r -> isequal(r.name, "search_sorted"), code))
    @test occursin("binary search", lowercase(something(node.summary, "")))
end

@testset "R18: is_sorted summary comes from preceding comment (no docstring)" begin
    code = _db().code
    node = only(filter(r -> isequal(r.name, "is_sorted"), code))
    @test occursin("sorted", lowercase(something(node.summary, "")))
end

@testset "R19: DataProcessor module summary comes from module-level docstring" begin
    code = _db().code
    dp = only(filter(r -> isequal(r.name, "DataProcessor"), code))
    @test occursin("sorting", lowercase(something(dp.summary, "")))
end

@testset "R19: codebase root summary comes from README.md first paragraph" begin
    code = _db().code
    root_node = only(filter(r -> r.kind == "codebase", code))
    @test !ismissing(root_node.summary)
    @test occursin("minimal", lowercase(something(root_node.summary, "")))
end

@testset "R20: swap has missing summary (blank line breaks R14b absorption)" begin
    code = _db().code
    sw = only(filter(r -> isequal(r.name, "swap"), code))
    @test ismissing(sw.summary)
end

@testset "R20: noop has missing summary (blank line before declaration)" begin
    code = _db().code
    node = only(filter(r -> isequal(r.name, "noop"), code))
    @test ismissing(node.summary)
end

@testset "R20a: standalone comment node has its own source as summary" begin
    code = _db().code
    # "/* Section: globals and helpers */" is a standalone kind=comment node
    cmt = only(filter(r -> r.kind == "comment" &&
                      occursin("globals", something(r.source, "")), code))
    @test occursin("globals", something(cmt.summary, ""))
end

# =============================================================================
# Phase 6 — Symbol Extraction (R21, R21a, R21b, R21c, R22)
# =============================================================================

@testset "R21: call symbols recorded for main() leaf — quick_sort, timed_sort, process" begin
    code = _db().code
    syms = _db().symbols
    main_leaves = filter(r -> isequal(r.file, "src/main.cpp") && r.n_children == 0, code)
    calls = filter(r -> r.kind == "call" && r.node_id in main_leaves.id, syms)
    @test "quick_sort" in calls.symbol
    @test "timed_sort" in calls.symbol
    @test "process"    in calls.symbol
end

@testset "R21: var_ref symbols exclude locally-defined names (n, data, raw, s, idx)" begin
    code = _db().code
    syms = _db().symbols
    main_leaves = filter(r -> isequal(r.file, "src/main.cpp") && r.n_children == 0, code)
    var_refs = filter(r -> r.kind == "var_ref" && r.node_id in main_leaves.id, syms)
    for local_name in ("n", "data", "raw", "s", "idx")
        @test local_name ∉ var_refs.symbol
    end
end

@testset "R21: MAX_N appears as var_ref in main.cpp leaves" begin
    code = _db().code
    syms = _db().symbols
    main_leaves = filter(r -> isequal(r.file, "src/main.cpp") && r.n_children == 0, code)
    var_refs = filter(r -> r.kind == "var_ref" && r.node_id in main_leaves.id, syms)
    @test "MAX_N" in var_refs.symbol
end

@testset "R21a: Markdown tagged fenced block — quick_sort in api.md symbols" begin
    code = _db().code
    syms = _db().symbols
    api_leaves = filter(r -> isequal(r.file, "docs/api.md") && r.n_children == 0, code)
    api_syms = filter(r -> r.node_id in api_leaves.id, syms)
    @test "quick_sort" in api_syms.symbol
end

@testset "R21a: Markdown untagged block — compute_stats and DataStats in api.md; MyUnknownType absent" begin
    code = _db().code
    syms = _db().symbols
    api_leaves = filter(r -> isequal(r.file, "docs/api.md") && r.n_children == 0, code)
    api_syms = filter(r -> r.node_id in api_leaves.id, syms)
    @test "compute_stats"  in api_syms.symbol
    @test "DataStats"      in api_syms.symbol
    @test "MyUnknownType" ∉ api_syms.symbol
end

@testset "R21a: README.md untagged block — quick_sort and sort_array present; unknown_algorithm absent" begin
    code = _db().code
    syms = _db().symbols
    readme_leaves = filter(r -> isequal(r.file, "README.md") && r.n_children == 0, code)
    readme_syms = filter(r -> r.node_id in readme_leaves.id, syms)
    @test "quick_sort"        in readme_syms.symbol
    @test "sort_array"        in readme_syms.symbol
    @test "unknown_algorithm" ∉ readme_syms.symbol
end

@testset "R21c: Markdown heading/paragraph text does not appear in symbols" begin
    code = _db().code
    syms = _db().symbols
    readme_leaves = filter(r -> isequal(r.file, "README.md") && r.n_children == 0, code)
    readme_syms = filter(r -> r.node_id in readme_leaves.id, syms)
    @test "Structure"  ∉ readme_syms.symbol
    @test "Start"      ∉ readme_syms.symbol  # from "Quick Start" heading
end

@testset "R22: db.symbols rows have node_id, symbol, kind — no resolved references" begin
    syms = _db().symbols
    @test nrow(syms) > 0
    @test hasproperty(syms, :node_id)
    @test hasproperty(syms, :symbol)
    @test hasproperty(syms, :kind)
    # All kinds are one of the expected values
    @test all(k -> k ∈ ("call", "var_ref"), syms.kind)
end

# ===========================================================================
# Phase 7 — Caching (R24, R25, R26, R27, R28)
#
# All cache tests operate on a temp copy of the fixture to avoid polluting
# the canonical test_codebase with .7aigent/ artifacts.
# ===========================================================================

# Helper: copy the test_codebase tree into a fresh temp directory.
function _tmp_codebase()
    tmp = mktempdir()
    for (root, dirs, files) in walkdir(TEST_CODEBASE)
        rel = relpath(root, TEST_CODEBASE)
        dst_dir = joinpath(tmp, rel)
        isdir(dst_dir) || mkpath(dst_dir)
        for f in files
            cp(joinpath(root, f), joinpath(dst_dir, f))
        end
    end
    # Reproduce the .gitignore so discovery works the same way
    gi_src = joinpath(TEST_CODEBASE, ".gitignore")
    isfile(gi_src) && cp(gi_src, joinpath(tmp, ".gitignore"), force=true)
    # git init so git ls-files works
    run(pipeline(Cmd(`git init`; dir=tmp); stdout=devnull, stderr=devnull); wait=true)
    run(pipeline(Cmd(`git add -A`; dir=tmp); stdout=devnull, stderr=devnull); wait=true)
    run(pipeline(Cmd(`git -c user.email=x@x -c user.name=x commit -m init`; dir=tmp);
                 stdout=devnull, stderr=devnull); wait=true)
    return tmp
end

@testset "R24: cache stored at .7aigent/code_tree/ under the codebase root" begin
    tmp = _tmp_codebase()
    try
        load(tmp, TEST_CONFIG)
        cache_dir = joinpath(tmp, ".7aigent", "code_tree")
        @test isdir(cache_dir)
        # At least one SQLite db file exists inside the cache dir
        db_files = filter(f -> endswith(f, ".db"), readdir(cache_dir))
        @test length(db_files) >= 1
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R25: SQLite cache has a files table with path, hash, commit_hash columns" begin
    tmp = _tmp_codebase()
    try
        load(tmp, TEST_CONFIG)
        cache_db_path = joinpath(tmp, ".7aigent", "code_tree", "index.db")
        @test isfile(cache_db_path)
        db = SQLite.DB(cache_db_path)
        tables = SQLite.tables(db) |> x -> [t.name for t in x]
        @test "files" ∈ tables
        files_df = DBInterface.execute(db, "SELECT * FROM files") |> DataFrame
        @test hasproperty(files_df, :path)
        @test hasproperty(files_df, :hash)
        @test hasproperty(files_df, :commit_hash)
        # Every discovered source file is represented
        @test nrow(files_df) > 0
        # SHA-256 hashes are non-empty hex strings
        @test all(h -> !ismissing(h) && length(h) == 64, files_df.hash)
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R25 + R26: code and symbols tables are persisted in SQLite cache" begin
    tmp = _tmp_codebase()
    try
        db1 = load(tmp, TEST_CONFIG)
        cache_db_path = joinpath(tmp, ".7aigent", "code_tree", "index.db")
        sdb = SQLite.DB(cache_db_path)
        tables = SQLite.tables(sdb) |> x -> [t.name for t in x]
        @test "code" ∈ tables
        @test "symbols" ∈ tables
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R26: second load of unchanged codebase produces identical db.code" begin
    tmp = _tmp_codebase()
    try
        db1 = load(tmp, TEST_CONFIG)
        db2 = load(tmp, TEST_CONFIG)
        # Same number of rows
        @test nrow(db1.code) == nrow(db2.code)
        # Same ids (order may differ — sort first)
        @test sort(db1.code.id) == sort(db2.code.id)
        # Same symbol count
        @test nrow(db1.symbols) == nrow(db2.symbols)
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R27: changed file is re-parsed; its rows reflect new content" begin
    tmp = _tmp_codebase()
    try
        db1 = load(tmp, TEST_CONFIG)
        # Count rows from core.jl before modification
        rows_before = nrow(filter(r -> isequal(r.file, "julia/core.jl"), db1.code))
        @test rows_before > 0

        # Overwrite core.jl with minimal content (single function)
        core_path = joinpath(tmp, "julia", "core.jl")
        write(core_path, "function tiny_fn()\n  return 1\nend\n")
        run(pipeline(Cmd(`git add julia/core.jl`; dir=tmp); stdout=devnull, stderr=devnull); wait=true)
        run(pipeline(Cmd(`git -c user.email=x@x -c user.name=x commit -m update`; dir=tmp);
                     stdout=devnull, stderr=devnull); wait=true)

        db2 = load(tmp, TEST_CONFIG)
        rows_after = filter(r -> isequal(r.file, "julia/core.jl"), db2.code)
        # The rewritten file has fewer rows than the original
        @test nrow(rows_after) < rows_before
        # The new function name appears
        @test any(r -> isequal(r.name, "tiny_fn"), eachrow(rows_after))
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R28: deleted file has its rows removed from db.code after re-load" begin
    tmp = _tmp_codebase()
    try
        db1 = load(tmp, TEST_CONFIG)
        @test any(r -> isequal(r.file, "julia/utils.jl"), eachrow(db1.code))

        # Delete utils.jl
        rm(joinpath(tmp, "julia", "utils.jl"))
        run(pipeline(Cmd(`git rm julia/utils.jl`; dir=tmp); stdout=devnull, stderr=devnull); wait=true)
        run(pipeline(Cmd(`git -c user.email=x@x -c user.name=x commit -m delete`; dir=tmp);
                     stdout=devnull, stderr=devnull); wait=true)

        db2 = load(tmp, TEST_CONFIG)
        @test !any(r -> isequal(r.file, "julia/utils.jl"), eachrow(db2.code))
    finally
        rm(tmp; recursive=true)
    end
end

# ===========================================================================
# Phase 8 — load/reload integration and in-memory buffer (R29)
# ===========================================================================

@testset "R29: all discovered files are in db._buffer after load" begin
    db = _db()
    # Every file that appears in db.code should have an entry in the buffer.
    file_cols = skipmissing(db.code.file) |> unique |> collect
    for f in file_cols
        @test haskey(db._buffer, f)
    end
    # Buffer entries are non-empty strings matching on-disk content.
    for (rel, src) in db._buffer
        abs_path = joinpath(db.root, rel)
        @test isfile(abs_path)
        @test src == read(abs_path, String)
    end
end

@testset "R29: db.code source column comes from buffer, not re-read from disk" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        # Overwrite a file on disk AFTER load (without calling load again)
        write(joinpath(tmp, "julia", "utils.jl"), "# tampered\n")

        # The buffer should still have the original content
        original = db._buffer["julia/utils.jl"]
        @test !occursin("tampered", original)

        # db.code source for utils.jl nodes should come from the original buffer
        utils_rows = filter(r -> isequal(r.file, "julia/utils.jl") && !ismissing(r.source), db.code)
        for row in eachrow(utils_rows)
            @test !occursin("tampered", row.source)
        end
    finally
        rm(tmp; recursive=true)
    end
end

@testset "reload: after external file change, db is updated in-place" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        original_id = objectid(db)

        # Modify a file externally
        write(joinpath(tmp, "julia", "utils.jl"), "function reloaded_fn()\n  42\nend\n")
        run(pipeline(Cmd(`git add julia/utils.jl`; dir=tmp); stdout=devnull, stderr=devnull); wait=true)
        run(pipeline(Cmd(`git -c user.email=x@x -c user.name=x commit -m reload`; dir=tmp);
                     stdout=devnull, stderr=devnull); wait=true)

        reload(db)

        # Same object, updated content
        @test objectid(db) == original_id
        @test any(r -> isequal(r.name, "reloaded_fn"), eachrow(db.code))
        @test db._buffer["julia/utils.jl"] == "function reloaded_fn()\n  42\nend\n"
    finally
        rm(tmp; recursive=true)
    end
end

# ===========================================================================
# Phase 9 — update_source (R30–R35)
# ===========================================================================

@testset "R30: update_source succeeds and updates db.code" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        new_src = "function is_sorted(v)\n    return true\nend\n"
        update_source(db, node.id, new_src)

        updated = filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code)
        @test nrow(updated) >= 1
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R30a: external file change detected; db refreshed; error raised" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        # Tamper with the file externally (bypass update_source)
        utils_path = joinpath(tmp, "julia", "utils.jl")
        write(utils_path, "function external_fn()\n  99\nend\n")

        @test_throws Exception update_source(db, node.id, "function is_sorted(v)\n  true\nend\n")

        # db must now reflect the externally modified content
        @test any(r -> isequal(r.name, "external_fn"), eachrow(db.code))
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R31: file content on disk after update is a splice of old content with new_source" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        utils_path     = joinpath(tmp, "julia", "utils.jl")
        original_lines = readlines(utils_path; keep=true)
        ls = node.line_start
        le = node.line_end

        new_src = "function is_sorted(v)\n    return true  # stub\nend\n"
        update_source(db, node.id, new_src)

        disk_lines = readlines(utils_path; keep=true)

        # Lines before the replaced span unchanged
        @test all(disk_lines[i] == original_lines[i] for i in 1:(ls - 1))
        # Lines after the replaced span unchanged
        orig_after = original_lines[(le + 1):end]
        new_after  = disk_lines[(ls - 1 + length(readlines(IOBuffer(new_src); keep=true)) + 1):end]
        @test orig_after == new_after
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R33 + R33a: db.code and db.symbols updated; old symbol rows replaced" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        update_source(db, node.id,
            "function is_sorted(v)\n    return issorted(v)\nend\n")

        # db.code has the updated function
        @test any(r -> isequal(r.name, "is_sorted"), eachrow(db.code))

        # Find updated node (id may have changed if line_start changed)
        new_node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        # No duplicate symbol rows for the new node
        relevant = filter(r -> isequal(r.node_id, new_node.id), db.symbols)
        @test nrow(unique(relevant)) == nrow(relevant)

        # Old node id has no symbols if id changed
        if new_node.id != node.id
            @test nrow(filter(r -> isequal(r.node_id, node.id), db.symbols)) == 0
        end
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R34: disk content after update_source matches db buffer" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        update_source(db, node.id,
            "function is_sorted(v)\n    return issorted(v)\nend\n")

        disk_content   = read(joinpath(tmp, node.file), String)
        buffer_content = db._buffer[node.file]
        @test disk_content == buffer_content
    finally
        rm(tmp; recursive=true)
    end
end

@testset "R35: failed disk write rolls back db to pre-call state" begin
    tmp = _tmp_codebase()
    try
        db = load(tmp, TEST_CONFIG)
        node = only(filter(r -> isequal(r.name, "is_sorted") && isequal(r.kind, "function"), db.code))

        ids_before        = sort(copy(db.code.id))
        buf_before        = db._buffer[node.file]  # String is immutable
        syms_count_before = nrow(db.symbols)

        # Make the file read-only so the disk write fails
        utils_path = joinpath(tmp, "julia", "utils.jl")
        chmod(utils_path, 0o444)

        @test_throws Exception update_source(db, node.id,
            "function is_sorted(v)\n    return issorted(v)\nend\n")

        @test sort(db.code.id)      == ids_before
        @test db._buffer[node.file] == buf_before
        @test nrow(db.symbols)      == syms_count_before

        chmod(utils_path, 0o644)
    finally
        rm(tmp; recursive=true)
    end
end
