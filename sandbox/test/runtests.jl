using Test
using CodeTree
using DataFrames

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using SevenAigentREPL

function _workspace_from_fixture()::String
    workspace = mktempdir()
    mkpath(joinpath(workspace, ".7aigent", "state"))
    mkpath(joinpath(workspace, "docs"))
    mkpath(joinpath(workspace, "julia"))
    mkpath(joinpath(workspace, "src"))
    mkpath(joinpath(workspace, "data"))

    write(
        joinpath(workspace, "README.md"),
        """
        # Test Workspace

        This workspace exists to exercise the REPL summary API.

        It includes a Julia module, extra docs, and a small C++ file.
        """,
    )

    write(
        joinpath(workspace, "docs", "api.md"),
        """
        # API

        The public API is intentionally tiny.
        """,
    )

    write(
        joinpath(workspace, "julia", "core.jl"),
        """
        \"\"\"
            module DataProcessor

        High-level sorting and statistics helpers.
        \"\"\"
        module DataProcessor

        \"\"\"
            compute_stats(v) -> Int

        Compute simple statistics for a vector.
        \"\"\"
        function compute_stats(v)
            return length(v)
        end

        # Binary search over a sorted vector.
        function search_sorted(v, x)
            return findfirst(==(x), v)
        end

        function noop(x)
            return x
        end

        end
        """,
    )

    write(
        joinpath(workspace, "src", "algorithms.cpp"),
        """
        // Lightweight helper implementation.
        int quick_sort(int value) {
            return value;
        }
        """,
    )

    write(joinpath(workspace, "data", "config.toml"), "name = \"demo\"\n")
    mkpath(joinpath(workspace, ".7aigent", "state"))
    run(pipeline(Cmd(`git init`; dir=workspace); stdout=devnull, stderr=devnull); wait=true)
    run(pipeline(Cmd(`git add -A`; dir=workspace); stdout=devnull, stderr=devnull); wait=true)
    run(
        pipeline(
            Cmd(`git -c user.email=x@x -c user.name=x commit -m init`; dir=workspace);
            stdout=devnull,
            stderr=devnull,
        );
        wait=true,
    )
    return workspace
end

function _write_summary_config!(
    workspace::String;
    max_targets_per_batch::Union{Int,Nothing} = nothing,
    max_prompt_chars::Union{Int,Nothing} = nothing,
    max_children_per_target::Union{Int,Nothing} = nothing,
    max_witness_chars::Union{Int,Nothing} = nothing,
    max_readme_chars::Union{Int,Nothing} = nothing,
)::Nothing
    entries = String[]
    !isnothing(max_targets_per_batch) && push!(entries, "max_targets_per_batch = $(max_targets_per_batch)")
    !isnothing(max_prompt_chars) && push!(entries, "max_prompt_chars = $(max_prompt_chars)")
    !isnothing(max_children_per_target) && push!(entries, "max_children_per_target = $(max_children_per_target)")
    !isnothing(max_witness_chars) && push!(entries, "max_witness_chars = $(max_witness_chars)")
    !isnothing(max_readme_chars) && push!(entries, "max_readme_chars = $(max_readme_chars)")
    write(
        joinpath(workspace, ".7aigent", "config.toml"),
        "[summaries]\n" * join(entries, "\n") * "\n",
    )
    return nothing
end

function _code_df(db::CodeTreeDB)::DataFrame
    return getfield(db.code, :_df)
end

function _bind_repl_session(workspace::String)::CodeTreeDB
    db = CodeTree.load(workspace)
    SevenAigentREPL.bind!(workspace, db)
    return db
end

function _capture_stdout(f::Function)::Tuple{String,Any}
    pipe = Pipe()
    result = redirect_stdout(pipe) do
        f()
    end
    close(pipe.in)
    output = String(read(pipe.out))
    return output, result
end

function _todo_index(df::AbstractDataFrame, id::Int)::Int
    idx = findfirst(==(id), df.id)
    isnothing(idx) && error("Expected todo id $id")
    return idx
end

function _node_id(
    db::CodeTreeDB;
    kind::AbstractString,
    name::Union{AbstractString,Nothing} = nothing,
    file::Union{AbstractString,Nothing} = nothing,
)::String
    df = _code_df(db)
    matches = filter(eachrow(df)) do row
        row.kind == kind &&
            (isnothing(name) || row.name == name) &&
            (isnothing(file) || (!ismissing(row.file) && row.file == file))
    end
    length(matches) == 1 || error("Expected exactly one node match, got $(length(matches))")
    return only(matches).id
end

@testset "RA3 + RA3.2: explicit DataFrame display helpers render compact markdown tables for startup delegation" begin
    df = DataFrame(alpha = ["value"], beta = [2])
    explicit_render = sprint(io -> SevenAigentREPL.llm_show_dataframe(io, df))
    wide_df = DataFrame((Symbol("col$(i)") => [i] for i in 1:22)...)
    wide_render = sprint(io -> SevenAigentREPL.llm_show_dataframe(io, wide_df))
    tall_df = DataFrame(alpha = 1:8)
    tall_buffer = IOBuffer()
    tall_io = IOContext(tall_buffer, :displaysize => (8, 80))
    SevenAigentREPL.llm_show_dataframe(tall_io, tall_df)
    tall_render = String(take!(tall_buffer))

    @test occursin("1 rows x 2 columns DataFrame", explicit_render)
    @test occursin("| Row | alpha :: String | beta :: Int64 |", explicit_render)
    @test occursin("| --- | --- | --- |", explicit_render)
    @test occursin("| 1 | value | 2 |", explicit_render)
    @test !occursin("│", explicit_render)
    @test occursin("2 more columns omitted", wide_render)
    @test occursin("4 more rows omitted", tall_render)
    @test SevenAigentREPL.llm_show_dataframe(df) === nothing
end

@testset "RA3.1 + RA3.2: startup-style text/markdown show delegation works for CodeTree tables" begin
    Base.show(io::IO, ::MIME"text/plain", df::DataFrame) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/markdown", df::DataFrame) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/plain", df::SubDataFrame) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/markdown", df::SubDataFrame) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/plain", df::CodeTree.CodeTree) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/markdown", df::CodeTree.CodeTree) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/plain", df::CodeTree.CodeSymbols) =
        SevenAigentREPL.llm_show_dataframe(io, df)
    Base.show(io::IO, ::MIME"text/markdown", df::CodeTree.CodeSymbols) =
        SevenAigentREPL.llm_show_dataframe(io, df)

    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    markdown_render = repr(MIME("text/markdown"), db.code)

    @test occursin("rows x 16 columns DataFrame", markdown_render)
    @test occursin("| Row | id :: String |", markdown_render)
    @test !occursin("MethodError", markdown_render)
end

@testset "RA3.1 + RA25 + RA27: bind! uses caller-provided db and bundled summary defaults" begin
    workspace = _workspace_from_fixture()
    db = CodeTree.load(workspace)
    @test_throws MethodError SevenAigentREPL.bind!(workspace)
    @test SevenAigentREPL.bind!(workspace, db) === nothing
    cfg = SevenAigentREPL.summary_config()

    @test isa(db, CodeTreeDB)
    @test cfg.max_targets_per_batch == 12
    @test cfg.max_prompt_chars == 12000
    @test cfg.max_children_per_target == 24
    @test cfg.max_witness_chars == 400
    @test cfg.max_readme_chars == 3000
end

@testset "RA25 + RA27: partial summaries config overrides only specified fields" begin
    workspace = _workspace_from_fixture()
    mkpath(joinpath(workspace, ".7aigent"))
    write(
        joinpath(workspace, ".7aigent", "config.toml"),
        """
        [summaries]
        max_targets_per_batch = 3
        max_witness_chars = 120
        """,
    )

    SevenAigentREPL.bind!(workspace, CodeTree.load(workspace))
    cfg = SevenAigentREPL.summary_config()

    @test cfg.max_targets_per_batch == 3
    @test cfg.max_prompt_chars == 12000
    @test cfg.max_children_per_target == 24
    @test cfg.max_witness_chars == 120
    @test cfg.max_readme_chars == 3000
end

@testset "RA4 + RA5: bind! keeps the caller's db and starts with an empty generated-summary store" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    @test isa(db, CodeTreeDB)
    @test nrow(SevenAigentREPL.generated_summaries()) == 0
    @test any(.!ismissing.(db.code.summary))
end

@testset "RA4 + RA5 + RA6 + RA7a: summarize! updates session db.code summaries in place and does not persist them" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    search_sorted_id = _node_id(db; kind = "function", name = "search_sorted", file = "julia/core.jl")
    compute_stats_id = _node_id(db; kind = "function", name = "compute_stats", file = "julia/core.jl")
    noop_id = _node_id(db; kind = "function", name = "noop", file = "julia/core.jl")

    captured_requests = Any[]
    SevenAigentREPL.set_summary_transport!(request -> begin
        push!(captured_requests, request)
        return Dict(
            search_sorted_id => "Generated summary for search_sorted.",
            compute_stats_id => "Generated summary for compute_stats.",
            noop_id => "Generated summary for noop.",
        )
    end)

    result = SevenAigentREPL.summarize!([compute_stats_id, search_sorted_id, noop_id])
    generated = SevenAigentREPL.generated_summaries()
    noop_row = only(filter(r -> r.id == noop_id, eachrow(_code_df(db))))
    reloaded_db = CodeTree.load(workspace)
    reloaded_noop_row = only(filter(r -> r.id == noop_id, eachrow(_code_df(reloaded_db))))

    @test result.id == [compute_stats_id, search_sorted_id, noop_id]
    @test nrow(result) == 3
    @test length(captured_requests) == 1
    @test all(id -> id in Set(captured_requests[1].target_ids), [search_sorted_id, compute_stats_id, noop_id])
    @test nrow(generated) == 3
    @test noop_row.summary == "Generated summary for noop."
    @test ismissing(reloaded_noop_row.summary)
end

@testset "RA5: generated summaries survive update_source! when the node id is unchanged" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    noop_id = _node_id(db; kind = "function", name = "noop", file = "julia/core.jl")
    SevenAigentREPL.set_summary_transport!(request ->
        Dict(id => "Generated summary for $(id)." for id in request.target_ids)
    )

    SevenAigentREPL.summarize!([noop_id])
    CodeTree.update_source!(
        db,
        noop_id,
        "return x" => "return x  # passthrough",
    )

    updated_noop = only(filter(r -> r.id == noop_id, eachrow(_code_df(db))))
    generated = SevenAigentREPL.generated_summaries()

    @test updated_noop.summary == "Generated summary for $(noop_id)."
    @test only(filter(r -> r.id == noop_id, eachrow(generated))).summary ==
        "Generated summary for $(noop_id)."
end

@testset "RA7: DataFrame-based summarize! updates a mutable summary column" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    search_sorted_id = _node_id(db; kind = "function", name = "search_sorted", file = "julia/core.jl")
    compute_stats_id = _node_id(db; kind = "function", name = "compute_stats", file = "julia/core.jl")
    frame = DataFrame(
        id = [search_sorted_id, compute_stats_id],
        summary = Union{String,Missing}[missing, missing],
    )

    SevenAigentREPL.set_summary_transport!(request ->
        Dict(id => "Updated summary for $(id)." for id in request.target_ids)
    )

    result = SevenAigentREPL.summarize!(frame)

    @test nrow(result) == 2
    @test frame.summary == [
        "Updated summary for $(search_sorted_id).",
        "Updated summary for $(compute_stats_id).",
    ]
end

@testset "RA8 + RA12: summarize! requests only explicit targets and deduplicates evidence payloads" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    file_id = _node_id(db; kind = "file", name = "core.jl", file = "julia/core.jl")
    captured_request = Ref{Any}(nothing)
    SevenAigentREPL.set_summary_transport!(request -> begin
        captured_request[] = request
        return Dict(file_id => "Generated file summary.")
    end)

    result = SevenAigentREPL.summarize!([file_id])
    request = captured_request[]

    @test result.id == [file_id]
    @test request.target_ids == [file_id]
    @test length(unique(node.id for node in request.evidence.nodes)) == length(request.evidence.nodes)
    @test length(unique(witness.id for witness in request.evidence.witnesses)) == length(request.evidence.witnesses)
end

@testset "RA9 + RA10 + RA11: summarize! batches by tree locality rather than raw input order" begin
    workspace = _workspace_from_fixture()
    _write_summary_config!(workspace; max_targets_per_batch = 2)
    db = _bind_repl_session(workspace)

    docs_id = _node_id(db; kind = "file", name = "api.md", file = "docs/api.md")
    search_sorted_id = _node_id(db; kind = "function", name = "search_sorted", file = "julia/core.jl")
    compute_stats_id = _node_id(db; kind = "function", name = "compute_stats", file = "julia/core.jl")

    requests = Any[]
    SevenAigentREPL.set_summary_transport!(request -> begin
        push!(requests, request)
        return Dict(id => "Summary for $(id)." for id in request.target_ids)
    end)

    SevenAigentREPL.summarize!([compute_stats_id, docs_id, search_sorted_id])

    @test nrow(SevenAigentREPL.generated_summaries()) == 3
    @test length(requests) == 2
    @test requests[1].target_ids == [docs_id]
    @test requests[2].target_ids == [compute_stats_id, search_sorted_id]
end

@testset "RA33 + RA9: summarize! prints progress and descendant-sweep advisory output" begin
    workspace = _workspace_from_fixture()
    _write_summary_config!(workspace; max_targets_per_batch = 2)
    db = _bind_repl_session(workspace)

    docs_id = _node_id(db; kind = "file", name = "api.md", file = "docs/api.md")
    search_sorted_id = _node_id(db; kind = "function", name = "search_sorted", file = "julia/core.jl")
    compute_stats_id = _node_id(db; kind = "function", name = "compute_stats", file = "julia/core.jl")

    SevenAigentREPL.set_summary_transport!(request ->
        Dict(id => "Summary for $(id)." for id in request.target_ids)
    )

    output, result = _capture_stdout() do
        SevenAigentREPL.summarize!([compute_stats_id, docs_id, search_sorted_id])
    end

    @test nrow(result) == 3
    @test occursin("summarize!: starting 3 targets across 2 batches.", output)
    @test occursin("summarize!: advisory: selection mixes file and non-file rows;", output)
    @test occursin("summarize!: batch 1/2 starting (1 target).", output)
    @test occursin("summarize!: batch 1/2 done (1 update).", output)
    @test occursin("summarize!: batch 2/2 starting (2 targets).", output)
    @test occursin("summarize!: batch 2/2 done (2 updates).", output)
    @test occursin("summarize!: completed 3 targets across 2 batches; 3 updates.", output)
end

@testset "RA13-RA18 + RA20 + RA21: root evidence promotes README and records overflow metadata" begin
    workspace = _workspace_from_fixture()
    _write_summary_config!(workspace; max_children_per_target = 2)
    db = _bind_repl_session(workspace)

    root_id = only(filter(r -> ismissing(r.parent), eachrow(_code_df(db)))).id
    captured_request = Ref{Any}(nothing)
    SevenAigentREPL.set_summary_transport!(request -> begin
        captured_request[] = request
        return Dict(root_id => "Generated root summary.")
    end)

    SevenAigentREPL.summarize!([root_id])
    target = only(captured_request[].evidence.targets)

    @test !ismissing(target.promoted_readme_id)
    @test first(target.child_ids) == target.promoted_readme_id
    @test !ismissing(target.overflow)
    @test target.overflow.n_children_omitted > 0
end

@testset "RA29: TodoStatus enum is defined and all three values are exported" begin
    @test isdefined(SevenAigentREPL, :TodoStatus)
    @test SevenAigentREPL.pending isa SevenAigentREPL.TodoStatus
    @test SevenAigentREPL.in_progress isa SevenAigentREPL.TodoStatus
    @test SevenAigentREPL.done isa SevenAigentREPL.TodoStatus
    @test SevenAigentREPL.pending != SevenAigentREPL.in_progress
    @test SevenAigentREPL.in_progress != SevenAigentREPL.done
    @test SevenAigentREPL.pending != SevenAigentREPL.done
end

@testset "RA30: bind! initialises Main.todo as an empty hierarchical DataFrame with the correct schema" begin
    workspace = _workspace_from_fixture()
    db = CodeTree.load(workspace)
    SevenAigentREPL.bind!(workspace, db)

    @test isdefined(Main, :todo)
    @test Main.todo isa DataFrame
    @test nrow(Main.todo) == 0
    @test eltype(Main.todo.id) == Int
    @test eltype(Main.todo.parent) == Union{Missing, Int}
    @test eltype(Main.todo.description) == String
    @test eltype(Main.todo.status) == SevenAigentREPL.TodoStatus
end

@testset "RA30: bind! overwrites any existing Main.todo" begin
    workspace = _workspace_from_fixture()
    db = CodeTree.load(workspace)
    SevenAigentREPL.bind!(workspace, db)
    push!(Main.todo, (id=1, parent=missing, description="old task", status=SevenAigentREPL.pending))
    @test nrow(Main.todo) == 1
    SevenAigentREPL.bind!(workspace, db)
    @test nrow(Main.todo) == 0
end

@testset "RA31: todo_add! appends top-level pending rows and continues from the current max id" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    id1 = SevenAigentREPL.todo_add!("First task")
    push!(Main.todo, (id=5, parent=missing, description="existing", status=SevenAigentREPL.pending))
    id2 = SevenAigentREPL.todo_add!("Second task")

    @test id1 == 1
    @test id2 == 6
    @test nrow(Main.todo) == 3
    @test all(ismissing, Main.todo.parent)
    @test all(==(SevenAigentREPL.pending), Main.todo.status)
    @test Main.todo[1, :description] == "First task"
    @test Main.todo[3, :description] == "Second task"
end

@testset "RA31: todo_add! inserts child and sibling rows in DataFrame order" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    top1 = SevenAigentREPL.todo_add!("Top 1")
    child1 = SevenAigentREPL.todo_add!("Child 1"; parent=top1)
    child2 = SevenAigentREPL.todo_add!("Child 2"; after=child1)
    top2 = SevenAigentREPL.todo_add!("Top 2")

    @test [row.description for row in eachrow(Main.todo)] == ["Top 1", "Child 1", "Child 2", "Top 2"]
    @test collect(Main.todo.id) == [top1, child1, child2, top2]
    @test isequal(collect(Main.todo.parent), Union{Missing, Int}[missing, top1, top1, missing])
end

@testset "RA31: todo_add! can insert the first child immediately after its parent" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Parent task")
    child_id = SevenAigentREPL.todo_add!("First child"; parent=parent_id, after=parent_id)

    @test [row.description for row in eachrow(Main.todo)] == ["Parent task", "First child"]
    @test collect(Main.todo.id) == [parent_id, child_id]
    @test isequal(collect(Main.todo.parent), Union{Missing, Int}[missing, parent_id])
end

@testset "RA31: todo_add! splits the current task into subtasks when adding a child" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Investigate failing test")
    SevenAigentREPL.todo_start!(parent_id)
    child_id = SevenAigentREPL.todo_add!("Capture repro"; parent=parent_id)

    parent_idx = _todo_index(Main.todo, parent_id)
    child_idx = _todo_index(Main.todo, child_id)
    @test Main.todo[parent_idx, :status] == SevenAigentREPL.pending
    @test Main.todo[child_idx, :parent] == parent_id
    @test Main.todo[child_idx, :status] == SevenAigentREPL.in_progress
end

@testset "RA31: todo_start! focuses a pending leaf and clears the previous in_progress leaf" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Parent task")
    SevenAigentREPL.todo_start!(parent_id)
    first_child = SevenAigentREPL.todo_add!("First child"; parent=parent_id)
    second_child = SevenAigentREPL.todo_add!("Second child"; after=first_child)

    SevenAigentREPL.todo_start!(second_child)

    first_idx = _todo_index(Main.todo, first_child)
    second_idx = _todo_index(Main.todo, second_child)
    @test Main.todo[first_idx, :status] == SevenAigentREPL.pending
    @test Main.todo[second_idx, :status] == SevenAigentREPL.in_progress
end

@testset "RA31: todo_start! throws for missing, non-leaf, or done targets" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Parent task")
    child_id = SevenAigentREPL.todo_add!("Child task"; parent=parent_id)

    @test_throws ErrorException SevenAigentREPL.todo_start!(99)
    @test_throws ErrorException SevenAigentREPL.todo_start!(parent_id)

    SevenAigentREPL.todo_start!(child_id)
    SevenAigentREPL.todo_next!()
    @test_throws ErrorException SevenAigentREPL.todo_start!(child_id)
end

@testset "RA31: todo_next! marks the current leaf done, advances focus, and completes ancestors" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Release feature")
    SevenAigentREPL.todo_start!(parent_id)
    child1 = SevenAigentREPL.todo_add!("Build package"; parent=parent_id)
    child2 = SevenAigentREPL.todo_add!("Run smoke tests"; after=child1)
    top2 = SevenAigentREPL.todo_add!("Announce release")

    SevenAigentREPL.todo_next!()
    @test Main.todo[_todo_index(Main.todo, child1), :status] == SevenAigentREPL.done
    @test Main.todo[_todo_index(Main.todo, child2), :status] == SevenAigentREPL.in_progress
    @test Main.todo[_todo_index(Main.todo, parent_id), :status] == SevenAigentREPL.pending

    SevenAigentREPL.todo_next!()
    @test Main.todo[_todo_index(Main.todo, child2), :status] == SevenAigentREPL.done
    @test Main.todo[_todo_index(Main.todo, parent_id), :status] == SevenAigentREPL.done
    @test Main.todo[_todo_index(Main.todo, top2), :status] == SevenAigentREPL.in_progress

    SevenAigentREPL.todo_next!()
    @test Main.todo[_todo_index(Main.todo, top2), :status] == SevenAigentREPL.done
    @test count(==(SevenAigentREPL.in_progress), Main.todo.status) == 0
end

@testset "RA31: todo_next! throws when there is no current in_progress leaf" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    SevenAigentREPL.todo_add!("Task to track")
    @test_throws ErrorException SevenAigentREPL.todo_next!()
end

@testset "RA32: status() syncs valid Main.todo edits and renders the current path plus next work" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Plan release")
    SevenAigentREPL.todo_start!(parent_id)
    current_id = SevenAigentREPL.todo_add!("Write migration"; parent=parent_id)
    SevenAigentREPL.todo_add!("Run smoke test"; after=current_id)
    SevenAigentREPL.todo_add!("Announce release")
    insert!(
        Main.todo,
        3,
        (id=10, parent=parent_id, description="Review dashboard", status=SevenAigentREPL.pending),
    )

    output, result = _capture_stdout(() -> SevenAigentREPL.status())

    @test result === nothing
    @test occursin("[Tasks:", output)
    @test occursin("Current path", output)
    @test occursin("Plan release", output)
    @test occursin("Write migration", output)
    @test occursin("Review dashboard", output)

    SevenAigentREPL.todo_start!(10)
    @test Main.todo[_todo_index(Main.todo, current_id), :status] == SevenAigentREPL.pending
    @test Main.todo[_todo_index(Main.todo, 10), :status] == SevenAigentREPL.in_progress
end

@testset "RA32: status() reports duplicate ids and missing parent references without losing the last good state" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    SevenAigentREPL.todo_add!("Original task")
    Core.eval(Main, :(
        todo = DataFrame(
            id = [1, 1, 2],
            parent = Union{Missing, Int}[missing, missing, 99],
            description = ["Original task", "Duplicate task", "Orphan child"],
            status = [SevenAigentREPL.pending, SevenAigentREPL.pending, SevenAigentREPL.pending],
        )
    ))

    output, result = _capture_stdout(() -> SevenAigentREPL.status())

    @test result === nothing
    @test occursin("duplicate", lowercase(output))
    @test occursin("parent", lowercase(output))

    Core.eval(Main, :(todo = nothing))
    SevenAigentREPL.todo_add!("Recovered task")
    @test [row.description for row in eachrow(Main.todo)] == ["Original task", "Recovered task"]
end

@testset "RA32: status() reports parent cycles" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    Core.eval(Main, :(
        todo = DataFrame(
            id = [1, 2],
            parent = Union{Missing, Int}[2, 1],
            description = ["A", "B"],
            status = [SevenAigentREPL.pending, SevenAigentREPL.pending],
        )
    ))

    output, result = _capture_stdout(() -> SevenAigentREPL.status())
    @test result === nothing
    @test occursin("cycle", lowercase(output))
end

@testset "RA32: status() reports multiple in_progress rows and non-leaf current work" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    Core.eval(Main, :(
        todo = DataFrame(
            id = [1, 2],
            parent = Union{Missing, Int}[missing, missing],
            description = ["A", "B"],
            status = [SevenAigentREPL.in_progress, SevenAigentREPL.in_progress],
        )
    ))

    multi_output, multi_result = _capture_stdout(() -> SevenAigentREPL.status())
    @test multi_result === nothing
    @test occursin("in_progress", multi_output)

    Core.eval(Main, :(
        todo = DataFrame(
            id = [1, 2],
            parent = Union{Missing, Int}[missing, 1],
            description = ["Parent", "Child"],
            status = [SevenAigentREPL.in_progress, SevenAigentREPL.pending],
        )
    ))

    leaf_output, leaf_result = _capture_stdout(() -> SevenAigentREPL.status())
    @test leaf_result === nothing
    @test occursin("leaf", lowercase(leaf_output))
end

@testset "RA32: status() reports non-DataFrame todo values and is silent when no session is active" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    SevenAigentREPL.todo_add!("Task to track")

    Core.eval(Main, :(todo = "not a dataframe"))
    invalid_output, invalid_result = _capture_stdout(() -> SevenAigentREPL.status())
    @test invalid_result === nothing
    @test occursin("dataframe", lowercase(invalid_output))

    SevenAigentREPL._session_ref[] = nothing
    silent_output, silent_result = _capture_stdout(() -> SevenAigentREPL.status())
    @test silent_result === nothing
    @test isempty(silent_output)
end

@testset "RA31: todo_next! prints the status tree after advancing" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Parent task")
    SevenAigentREPL.todo_start!(parent_id)
    child1 = SevenAigentREPL.todo_add!("Step one"; parent=parent_id)
    child2 = SevenAigentREPL.todo_add!("Step two"; after=child1)

    output, result = _capture_stdout(() -> SevenAigentREPL.todo_next!())

    @test result === nothing
    @test occursin("[Tasks:", output)
    @test occursin("Step two", output)
end

@testset "RA31: todo_next! prints all-done summary when no pending leaf remains" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    id = SevenAigentREPL.todo_add!("Only task")
    SevenAigentREPL.todo_start!(id)

    output, _ = _capture_stdout(() -> SevenAigentREPL.todo_next!())

    @test occursin("[Tasks:", output)
    @test occursin("done", lowercase(output))
end

@testset "RA32: status() shows last known-good state under a header after validation failure" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    id1 = SevenAigentREPL.todo_add!("First task")
    SevenAigentREPL.todo_start!(id1)

    Core.eval(Main, :(
        todo = DataFrame(
            id = [1, 1],
            parent = Union{Missing, Int}[missing, missing],
            description = ["First task", "Duplicate"],
            status = [SevenAigentREPL.in_progress, SevenAigentREPL.pending],
        )
    ))

    output, result = _capture_stdout(() -> SevenAigentREPL.status())

    @test result === nothing
    @test occursin("duplicate", lowercase(output))
    @test occursin("last known-good", lowercase(output))
    @test occursin("First task", output)
end

@testset "RA32: status() does not print last known-good header when todo_df is empty" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    Core.eval(Main, :(todo = "bad value"))
    output, result = _capture_stdout(() -> SevenAigentREPL.status())

    @test result === nothing
    @test occursin("dataframe", lowercase(output))
    @test !occursin("last known-good", lowercase(output))
end

@testset "RA31: todo_refine_current! adds sibling children under the active leaf" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Parent")
    SevenAigentREPL.todo_start!(parent_id)

    ids = SevenAigentREPL.todo_refine_current!("Alpha", "Beta", "Gamma")

    @test length(ids) == 3
    descriptions = [row.description for row in eachrow(Main.todo)]
    @test "Alpha" in descriptions
    @test "Beta" in descriptions
    @test "Gamma" in descriptions

    alpha_idx = _todo_index(Main.todo, ids[1])
    @test Main.todo[alpha_idx, :parent] == parent_id
    @test Main.todo[alpha_idx, :status] == SevenAigentREPL.in_progress
    @test Main.todo[_todo_index(Main.todo, parent_id), :status] == SevenAigentREPL.pending

    beta_idx = _todo_index(Main.todo, ids[2])
    @test Main.todo[beta_idx, :parent] == parent_id
    @test Main.todo[beta_idx, :status] == SevenAigentREPL.pending
end

@testset "RA31: todo_refine_current! prints the status tree after adding children" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    id = SevenAigentREPL.todo_add!("Root task")
    SevenAigentREPL.todo_start!(id)

    output, result = _capture_stdout(() -> SevenAigentREPL.todo_refine_current!("Sub-task A", "Sub-task B"))

    @test result isa Vector{Int}
    @test occursin("[Tasks:", output)
    @test occursin("Sub-task A", output)
end

@testset "RA31: todo_refine_current! throws when called with no arguments" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    SevenAigentREPL.todo_add!("Root task")

    @test_throws ArgumentError SevenAigentREPL.todo_refine_current!()
end

@testset "RA31: todo_refine_current! throws when there is no in_progress leaf" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    SevenAigentREPL.todo_add!("Root task")

    @test_throws ErrorException SevenAigentREPL.todo_refine_current!("Child")
end

@testset "RA31: todo_delete! removes a pending leaf and prints the updated tree" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    id1 = SevenAigentREPL.todo_add!("Keep this")
    id2 = SevenAigentREPL.todo_add!("Delete this")

    output, result = _capture_stdout(() -> SevenAigentREPL.todo_delete!(id2))

    @test result === nothing
    @test nrow(Main.todo) == 1
    @test Main.todo[1, :description] == "Keep this"
    @test occursin("[Tasks:", output)
end

@testset "RA31: todo_delete! throws for non-leaf, in_progress, or done nodes" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    parent_id = SevenAigentREPL.todo_add!("Parent")
    child_id = SevenAigentREPL.todo_add!("Child"; parent=parent_id)
    SevenAigentREPL.todo_start!(child_id)

    @test_throws ErrorException SevenAigentREPL.todo_delete!(parent_id)
    @test_throws ErrorException SevenAigentREPL.todo_delete!(child_id)

    SevenAigentREPL.todo_next!()
    @test_throws ErrorException SevenAigentREPL.todo_delete!(child_id)
end

@testset "RA31: todo_delete! throws for a missing id" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    SevenAigentREPL.todo_add!("A task")

    @test_throws ErrorException SevenAigentREPL.todo_delete!(99)
end

@testset "RA14: non-leaf targets use the leftmost leaf descendant as the primary witness" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    file_id = _node_id(db; kind = "file", name = "core.jl", file = "julia/core.jl")
    captured_request = Ref{Any}(nothing)
    SevenAigentREPL.set_summary_transport!(request -> begin
        captured_request[] = request
        return Dict(file_id => "Generated file summary.")
    end)

    SevenAigentREPL.summarize!([file_id])
    target = only(captured_request[].evidence.targets)
    witness = only(filter(w -> w.id == target.primary_witness_id, captured_request[].evidence.witnesses))

    @test occursin("module DataProcessor", witness.text)
end
