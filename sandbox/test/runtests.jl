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
    @test cfg.max_targets_per_batch == 16
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

@testset "RA5: generated summaries survive update_source when the node id is unchanged" begin
    workspace = _workspace_from_fixture()
    db = _bind_repl_session(workspace)

    noop_id = _node_id(db; kind = "function", name = "noop", file = "julia/core.jl")
    SevenAigentREPL.set_summary_transport!(request ->
        Dict(id => "Generated summary for $(id)." for id in request.target_ids)
    )

    SevenAigentREPL.summarize!([noop_id])
    CodeTree.update_source(
        db,
        noop_id,
        "function noop(x)\n    y = x + 1\n    return y - 1\nend\n",
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

@testset "RA30: bind! initialises Main.todo as an empty DataFrame with the correct schema" begin
    workspace = _workspace_from_fixture()
    db = CodeTree.load(workspace)
    SevenAigentREPL.bind!(workspace, db)

    @test isdefined(Main, :todo)
    @test Main.todo isa DataFrame
    @test nrow(Main.todo) == 0
    @test eltype(Main.todo.id) == Int
    @test eltype(Main.todo.description) == String
    @test eltype(Main.todo.status) == SevenAigentREPL.TodoStatus
end

@testset "RA30: bind! overwrites any existing Main.todo" begin
    workspace = _workspace_from_fixture()
    db = CodeTree.load(workspace)
    SevenAigentREPL.bind!(workspace, db)
    push!(Main.todo, (id=1, description="old task", status=SevenAigentREPL.pending))
    @test nrow(Main.todo) == 1
    SevenAigentREPL.bind!(workspace, db)
    @test nrow(Main.todo) == 0
end

@testset "RA31: todo_add! appends pending rows with auto-incrementing ids" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)

    id1 = SevenAigentREPL.todo_add!("First task")
    id2 = SevenAigentREPL.todo_add!("Second task")
    id3 = SevenAigentREPL.todo_add!("Third task")

    @test id1 == 1
    @test id2 == 2
    @test id3 == 3
    @test nrow(Main.todo) == 3
    @test all(==(SevenAigentREPL.pending), Main.todo.status)
    @test Main.todo[1, :description] == "First task"
    @test Main.todo[2, :description] == "Second task"
end

@testset "RA31: todo_add! continues from the current max id" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    push!(Main.todo, (id=5, description="existing", status=SevenAigentREPL.pending))
    new_id = SevenAigentREPL.todo_add!("new task")
    @test new_id == 6
end

@testset "RA31: todo_start! sets the item to in_progress" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    id = SevenAigentREPL.todo_add!("Task to start")
    SevenAigentREPL.todo_start!(id)
    @test Main.todo[1, :status] == SevenAigentREPL.in_progress
end

@testset "RA31: todo_start! throws if another item is already in_progress" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    id1 = SevenAigentREPL.todo_add!("First")
    id2 = SevenAigentREPL.todo_add!("Second")
    SevenAigentREPL.todo_start!(id1)
    @test_throws ErrorException SevenAigentREPL.todo_start!(id2)
    @test Main.todo[1, :status] == SevenAigentREPL.in_progress
    @test Main.todo[2, :status] == SevenAigentREPL.pending
end

@testset "RA31: todo_start! throws if id does not exist" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    @test_throws ErrorException SevenAigentREPL.todo_start!(99)
end

@testset "RA31: todo_done! marks the item as done" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    id = SevenAigentREPL.todo_add!("Task to complete")
    SevenAigentREPL.todo_start!(id)
    SevenAigentREPL.todo_done!(id)
    @test Main.todo[1, :status] == SevenAigentREPL.done
end

@testset "RA31: todo_done! throws if id does not exist" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    @test_throws ErrorException SevenAigentREPL.todo_done!(99)
end

@testset "RA32: status() returns nothing and prints task summary" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    id1 = SevenAigentREPL.todo_add!("Explore codebase")
    id2 = SevenAigentREPL.todo_add!("Fix the bug")
    SevenAigentREPL.todo_start!(id1)

    output, result = _capture_stdout(() -> SevenAigentREPL.status())

    @test result === nothing
    @test occursin("in progress", output)
    @test occursin("Explore codebase", output)
    @test occursin("Fix the bug", output)
end

@testset "RA32: status() does not throw when Main.todo is overwritten with non-DataFrame" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    id1 = SevenAigentREPL.todo_add!("Task to track")
    # Simulate the model accidentally overwriting Main.todo with a non-DataFrame
    Core.eval(Main, :(todo = "not a dataframe"))
    # status() should still work because it reads from the session, not Main.todo
    output, result = _capture_stdout(() -> SevenAigentREPL.status())
    @test result === nothing
    @test occursin("Task to track", output)
end

@testset "RA32: status() is silent when no session is active" begin
    SevenAigentREPL._session_ref[] = nothing
    output, result = _capture_stdout(() -> SevenAigentREPL.status())
    @test result === nothing
    @test isempty(output)
end

@testset "RA32: todo mutations sync Main.todo for display; status() reads session state" begin
    workspace = _workspace_from_fixture()
    _bind_repl_session(workspace)
    SevenAigentREPL.todo_add!("Task A")
    SevenAigentREPL.todo_add!("Task B")
    SevenAigentREPL.todo_start!(1)

    # After mutations, Main.todo should reflect the current state (for REPL display)
    @test Main.todo isa DataFrame
    @test nrow(Main.todo) == 2

    # Even if Main.todo is overwritten, status() still reads from the session
    Core.eval(Main, :(todo = nothing))
    output, _ = _capture_stdout(() -> SevenAigentREPL.status())
    @test occursin("Task A", output)
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
