# load() and reload() — Phase 4 implementation.

"""
    load(root_path, config; detail_threshold=30) -> CodeTreeDB

Index the codebase rooted at `root_path` using `config` and return a read-only
`CodeTreeDB` containing `db.code` and `db.symbols`.

`detail_threshold` (default 30): compound nodes whose parent spans fewer lines
than this threshold are suppressed from `db.code` (R11, R12).
"""
function load(
    root_path::AbstractString,
    config::LanguageConfig;
    detail_threshold::Int = 30,
)::CodeTreeDB

    root_path = abspath(root_path)
    codebase_name = basename(root_path)

    # Discover files (relative paths from root_path)
    rel_files = discover_files(root_path)

    # Build all rows
    all_rows = Dict{Symbol,Any}[]

    # --- Codebase root node (R6) ---
    codebase_id = codebase_name
    push!(all_rows, _struct_row(codebase_id, missing, 0, 0, "codebase", codebase_name))

    # Group files by their parent directory.
    dir_to_files = Dict{String,Vector{String}}()
    for f in rel_files
        d = dirname(f)
        push!(get!(dir_to_files, d, String[]), f)
    end

    # --- Module nodes and root-level file nodes as children of codebase ---
    # All immediate children of the codebase root are numbered in a single
    # sorted sequence so sibling_order values are unique (R16).
    subdirs = sort(unique(filter(!isempty, dirname.(rel_files))))
    root_files = sort(get(dir_to_files, "", String[]))

    # Interleave: sort all codebase-root children alphabetically by name.
    root_children = vcat(subdirs, root_files)
    sort!(root_children, by = x -> basename(x))

    for (ci, child) in enumerate(root_children)
        if child in subdirs
            push!(all_rows, _struct_row(child, codebase_id, 1, ci - 1, "module", basename(child)))
        end
        # root-level files are handled below in the file-loop
    end

    # --- File nodes + their descendants (R6, R8, R10–R16) ---
    for d in sort(collect(keys(dir_to_files)))
        parent_id = isempty(d) ? codebase_id : d
        dir_files = sort(dir_to_files[d])
        depth = isempty(d) ? 1 : 2

        for rel in dir_files
            # Determine sibling_order: for root-level files use the merged index.
            if isempty(d)
                fi = findfirst(==(rel), root_children)
            else
                fi = findfirst(==(rel), dir_files)
            end

            abs_path = joinpath(root_path, rel)
            src = try read(abs_path, String) catch; "" end
            lang = language_for_file(config, rel)
            file_rows = build_file_rows(
                src, lang, config, detail_threshold,
                rel,       # file_id = relative path
                rel,       # file_path (used in :file column)
                parent_id,
                depth,
            )
            file_rows[1][:sibling_order] = fi - 1
            append!(all_rows, file_rows)
        end
    end

    # Post-process: fill n_children for codebase and module rows
    # (file rows have n_children filled by build_file_rows)
    id_to_children = Dict{String,Int}()
    for row in all_rows
        p = row[:parent]
        ismissing(p) && continue
        id_to_children[p] = get(id_to_children, p, 0) + 1
    end
    for row in all_rows
        if row[:kind] ∈ ("codebase", "module")
            row[:n_children] = get(id_to_children, row[:id], 0)
        end
    end

    # --- Assemble DataFrames ---
    code_df = _rows_to_dataframe(all_rows)

    # R19: assign README-based summaries to codebase root and module nodes.
    _assign_readme_summaries!(code_df, root_path)

    syms_df = DataFrame(node_id=String[], symbol=String[], kind=String[])

    buffer = Dict{String,String}()
    hashes = Dict{String,String}()
    for rel in rel_files
        abs_path = joinpath(root_path, rel)
        src = try read(abs_path, String) catch; "" end
        buffer[rel] = src
        hashes[rel]  = bytes2hex(SHA.sha256(src))
    end

    db = CodeTreeDB(
        CodeTree(code_df),
        CodeSymbols(syms_df),
        root_path,
        config,
        buffer,
        hashes,
    )
    return db
end

"""
    reload(db) -> CodeTreeDB

Re-index the codebase, detecting changed files and updating `db` in place.
Returns `db` for convenience.

Not yet implemented beyond a naive full reload.
"""
function reload(db::CodeTreeDB)::CodeTreeDB
    new_db = load(db.root, db.config)
    db.code    = new_db.code
    db.symbols = new_db.symbols
    db._buffer = new_db._buffer
    db._hashes = new_db._hashes
    return db
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Assign README-based summaries to codebase and module nodes (R19).
function _assign_readme_summaries!(df::DataFrame, root_path::String)
    for i in 1:nrow(df)
        kind = df[i, :kind]
        kind ∈ ("codebase", "module") || continue
        ismissing(df[i, :summary]) || continue  # already has a summary

        if kind == "codebase"
            readme = joinpath(root_path, "README.md")
        else
            mod_dir = String(df[i, :id])  # e.g. "src", "julia"
            readme = joinpath(root_path, mod_dir, "README.md")
        end
        s = _readme_summary(readme)
        if !ismissing(s)
            df[i, :summary] = s
        end
    end
end

function _struct_row(
    id::String, parent, depth::Int, sibling_order::Int, kind::String, name::String,
)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id            => id,
        :parent        => parent,
        :depth         => depth,
        :sibling_order => sibling_order,
        :kind          => kind,
        :name          => name,
        :qname         => missing,
        :language      => missing,
        :summary       => missing,
        :source        => missing,
        :signature     => missing,
        :file          => missing,
        :line_start    => missing,
        :line_end      => missing,
        :n_lines       => missing,
        :n_children    => 0,
    )
end

function _rows_to_dataframe(rows::Vector{Dict{Symbol,Any}})::DataFrame
    isempty(rows) && return DataFrame(
        id=String[], parent=Union{String,Missing}[], depth=Int[],
        sibling_order=Int[], kind=String[], name=String[],
        qname=Union{String,Missing}[], language=Union{String,Missing}[],
        summary=Union{String,Missing}[], source=Union{String,Missing}[],
        signature=Union{String,Missing}[], file=Union{String,Missing}[],
        line_start=Union{Int,Missing}[], line_end=Union{Int,Missing}[],
        n_lines=Union{Int,Missing}[], n_children=Int[],
    )

    n = length(rows)
    cols = (
        id            = Vector{String}(undef, n),
        parent        = Vector{Union{String,Missing}}(undef, n),
        depth         = Vector{Int}(undef, n),
        sibling_order = Vector{Int}(undef, n),
        kind          = Vector{String}(undef, n),
        name          = Vector{String}(undef, n),
        qname         = Vector{Union{String,Missing}}(undef, n),
        language      = Vector{Union{String,Missing}}(undef, n),
        summary       = Vector{Union{String,Missing}}(undef, n),
        source        = Vector{Union{String,Missing}}(undef, n),
        signature     = Vector{Union{String,Missing}}(undef, n),
        file          = Vector{Union{String,Missing}}(undef, n),
        line_start    = Vector{Union{Int,Missing}}(undef, n),
        line_end      = Vector{Union{Int,Missing}}(undef, n),
        n_lines       = Vector{Union{Int,Missing}}(undef, n),
        n_children    = Vector{Int}(undef, n),
    )

    for (i, row) in enumerate(rows)
        cols.id[i]            = row[:id]
        cols.parent[i]        = row[:parent]
        cols.depth[i]         = row[:depth]
        cols.sibling_order[i] = row[:sibling_order]
        cols.kind[i]          = row[:kind]
        cols.name[i]          = row[:name]
        cols.qname[i]         = row[:qname]
        cols.language[i]      = row[:language]
        cols.summary[i]       = row[:summary]
        cols.source[i]        = row[:source]
        cols.signature[i]     = row[:signature]
        cols.file[i]          = row[:file]
        cols.line_start[i]    = row[:line_start]
        cols.line_end[i]      = row[:line_end]
        cols.n_lines[i]       = row[:n_lines]
        cols.n_children[i]    = row[:n_children]
    end

    return DataFrame(
        id            = cols.id,
        parent        = cols.parent,
        depth         = cols.depth,
        sibling_order = cols.sibling_order,
        kind          = cols.kind,
        name          = cols.name,
        qname         = cols.qname,
        language      = cols.language,
        summary       = cols.summary,
        source        = cols.source,
        signature     = cols.signature,
        file          = cols.file,
        line_start    = cols.line_start,
        line_end      = cols.line_end,
        n_lines       = cols.n_lines,
        n_children    = cols.n_children,
    )
end
