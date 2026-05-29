# Startup helpers for a 7aigent workspace.

using CodeTree
using DataFrames, DataFramesMeta
using SevenAigentREPL

# Display strings as raw content (no quotes/escapes), matching how DataFrames are shown.
Base.show(io::IO, ::MIME"text/plain", s::String) = print(io, s)
Base.show(io::IO, ::MIME"text/markdown", s::String) = print(io, s)

Base.show(io::IO, df::DataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::DataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::DataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, df::SubDataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::SubDataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::SubDataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, df::CodeTree.CodeTree; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::CodeTree.CodeTree) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::CodeTree.CodeTree) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, df::CodeTree.CodeSymbols; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::CodeTree.CodeSymbols) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::CodeTree.CodeSymbols) =
    SevenAigentREPL.llm_show_dataframe(io, df)

global db = CodeTree.load("/workspace")
SevenAigentREPL.bind!("/workspace", db)

function todo_rewrite_current!(description::AbstractString)::Nothing
    current_rows = @subset(todo, :status .== in_progress)
    nrow(current_rows) == 1 ||
        throw(ErrorException("todo_rewrite_current! requires exactly one in_progress leaf."))
    current_id = only(current_rows.id)
    row_index = findfirst(==(current_id), todo.id)
    isnothing(row_index) &&
        throw(ErrorException("Current todo id $current_id not found."))
    todo[row_index, :description] = String(description)
    status()
    return nothing
end

function show_lines(path::AbstractString, start_line::Integer, end_line::Integer)::Nothing
    start_line <= end_line ||
        throw(ArgumentError("show_lines requires start_line <= end_line"))
    lines = split(read(String(path), String), '\n')
    from_line = max(1, Int(start_line))
    to_line = min(length(lines), Int(end_line))
    for i in from_line:to_line
        println("$(i): $(lines[i])")
    end
    return nothing
end

function show_md_section(path::AbstractString, heading_query::AbstractString)::Nothing
    lines = split(read(String(path), String), '\n')
    query = lowercase(String(heading_query))
    start_line = nothing
    start_level = 0

    for (i, line) in enumerate(lines)
        heading_match = match(r"^(#+)\s+(.*)$", line)
        isnothing(heading_match) && continue
        heading_text = lowercase(strip(heading_match.captures[2]))
        occursin(query, heading_text) || continue
        start_line = i
        start_level = length(heading_match.captures[1])
        break
    end

    isnothing(start_line) && throw(ArgumentError(
        "No Markdown heading containing \"$heading_query\" found in $path. " *
        "Retry the same file with show_matches(path, \"$heading_query\") or show_lines(path, a, b).",
    ))

    end_line = length(lines)
    for i in (start_line::Int + 1):length(lines)
        heading_match = match(r"^(#+)\s+(.*)$", lines[i])
        isnothing(heading_match) && continue
        if length(heading_match.captures[1]) <= start_level
            end_line = i - 1
            break
        end
    end

    show_lines(path, start_line::Int, end_line)
    return nothing
end

function show_matches(
    path::AbstractString,
    query::AbstractString;
    context_lines::Integer = 8,
    max_matches::Integer = 3,
)::Nothing
    context_lines >= 0 || throw(ArgumentError("show_matches requires context_lines >= 0"))
    max_matches >= 1 || throw(ArgumentError("show_matches requires max_matches >= 1"))

    lines = split(read(String(path), String), '\n')
    lowered_query = lowercase(String(query))
    match_lines = [
        i for (i, line) in enumerate(lines) if occursin(lowered_query, lowercase(line))
    ]

    isempty(match_lines) &&
        throw(ArgumentError("No lines containing \"$query\" found in $path"))

    emitted = 0
    last_end = 0
    for line_no in match_lines
        start_line = max(1, line_no - Int(context_lines))
        end_line = min(length(lines), line_no + Int(context_lines))
        start_line <= last_end && continue
        emitted += 1
        emitted > Int(max_matches) && break
        println("--- match $emitted at line $line_no ---")
        for i in start_line:end_line
            println("$(i): $(lines[i])")
        end
        last_end = end_line
        emitted < min(length(match_lines), Int(max_matches)) && println()
    end
    return nothing
end

if nrow(todo) == 0
    session_id = todo_add!("Understand and complete the current user task")
    todo_add!(
        "Read guide files directly, then immediately advance this scaffold with todo_next!()";
        parent = session_id,
        start = true,
    )
    todo_add!(
        "Choose the exact file/node/test or requirement section to inspect first; if you only know a directory/module, refine this leaf again before reading more code";
        parent = session_id,
    )
    todo_add!(
        "After choosing the target and reading just enough context, advance here and make the smallest useful change";
        parent = session_id,
    )
    todo_add!(
        "Run targeted checks, inspect the diff, and complete any remaining task-specific leaves";
        parent = session_id,
    )
end

println("db ready: $(nrow(db.code)) nodes. Do not call load() — db persists across all tool calls.")
println()

if isfile("AGENTS.md")
    println("AGENTS.md present — read it directly first.")
    println()
end

println("todo ready:")
SevenAigentREPL.status()
println("Use the printed hierarchy to stay oriented; `todo_next!()` and status() both render it.")
println("Inspect `todo` directly only when you need ids/parents or manual DataFrame edits.")
println("Helpers available here: todo_rewrite_current!(...), todo_refine_current!(...), todo_delete!(id), show_matches(...), show_md_section(...), show_lines(...)")
println("A concrete first work leaf names one exact file/node/test, requirement section, or a short 1-2 candidate comparison.")
println("If the active leaf still says 'explore architecture' or names a whole module/directory, refine again before reading more code.")
println("A leaf that names multiple docs/files is still too broad unless it is an explicit 1-2 candidate comparison.")
println("After `todo_next!()` moves you to the target-selection leaf, your next call should usually be `todo_rewrite_current!(...)` — not `root_nodes`, not `@subset`, and not `summarize!` yet.")
println("Once that target-selection leaf has done its job, use `todo_next!()` to move into the execution leaf instead of continuing to explore under the selection leaf.")
println("If the task already names a requirement ID, heading, symbol, or function, use that as your first anchor with show_matches(...), show_md_section(...), or show_lines(...).")
println("After todo_refine_current!(...) creates concrete child steps, work the first child immediately instead of continuing to browse under the parent.")
println("For large Markdown docs, prefer show_matches(path, \"needle\"), show_md_section(path, \"Heading\"), or show_lines(path, a, b) over whole-file reads.")
println("If show_md_section(...) misses, stay on the same file and retry with show_matches(...) or show_lines(...) before falling back to read(path, String).")
println("Whole-file read(path, String) on non-guide docs/source is a last resort once you know the exact file; prefer targeted helpers first.")
println("For directory or file surveys, `summarize!` on file rows is normal and often preferable; avoid mixed descendant sweeps that pull file rows and many descendants together, especially from broad `id` matching.")
println("If navigation data is weak, chunk-level `summarize!` is a valid fallback to keep raw code out of the main context. Narrow first when you can, then let a legitimate summarize run finish.")
println("If symbol lookup is sparse, fall back to a 1-3 file/chunk shortlist — not a whole-directory sweep.")
println("When file-row source is missing, inspect child rows with separate @subset predicates such as @subset(db.code, :parent .== file_id, .!ismissing.(:source)).")
println()
