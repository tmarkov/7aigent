# load() and reload() — with SQLite cache support (R24–R28).

"""
    load(root_path[, config]; detail_threshold=30) -> CodeTreeDB

Index the codebase rooted at `root_path` using `config` (defaults to
`DEFAULT_CONFIG`, which covers C/C++, Julia, and Markdown) and return a
`CodeTreeDB` containing `db.code` and `db.symbols`.

`detail_threshold` (default 30): compound nodes whose parent spans fewer lines
than this threshold are suppressed from `db.code` (R11, R12).

Unchanged files (same SHA-256 hash as the last `load`) are served from the
SQLite cache under `.7aigent/code_tree/index.db` without re-parsing (R26).
"""
function load(
    root_path::AbstractString,
    config::LanguageConfig = DEFAULT_CONFIG;
    detail_threshold::Int = 30,
)::CodeTreeDB

    root_path    = abspath(root_path)
    codebase_name = basename(root_path)
    commit_hash   = _current_commit_hash(root_path)

    # Open (or create) the SQLite cache.
    cache_db = _open_or_create_cache(root_path)

    # Discover files (relative paths from root_path)
    rel_files = discover_files(root_path)

    # Read all file sources into the buffer and compute hashes.
    buffer = Dict{String,String}()
    hashes = Dict{String,String}()
    for rel in rel_files
        src = try read(joinpath(root_path, rel), String) catch; "" end
        buffer[rel] = src
        hashes[rel]  = bytes2hex(SHA.sha256(src))
    end

    # --- Remove cache entries for files that no longer exist on disk (R28) ---
    current_set = Set(rel_files)
    for cached_path in _get_all_cached_paths(cache_db)
        cached_path ∉ current_set && _delete_file_from_cache!(cache_db, cached_path)
    end

    # Build all rows
    all_rows = CodeRow[]

    # --- Codebase root node (R6) ---
    codebase_id = NodeId(codebase_name)
    codebase_qname = QName(codebase_name)
    push!(all_rows, _struct_row(codebase_id, missing, 0, 0, NodeKind("codebase"), codebase_name, codebase_qname))

    # Group files by their parent directory.
    dir_to_files = Dict{String,Vector{String}}()
    for f in rel_files
        d = dirname(f)
        push!(get!(dir_to_files, d, String[]), f)
    end

    # --- Module nodes and root-level file nodes as children of codebase ---
    # All immediate children of the codebase root are numbered in a single
    # sorted sequence so sibling_order values are unique (R16).
    subdirs    = sort(unique(filter(!isempty, dirname.(rel_files))))
    root_files = sort(get(dir_to_files, "", String[]))

    root_children = vcat(subdirs, root_files)
    sort!(root_children, by = x -> basename(x))

    for (ci, child) in enumerate(root_children)
        if child in subdirs
            mod_qname = child_qname(codebase_qname, basename(child))
            push!(all_rows, _struct_row(NodeId(child), codebase_id, 1, ci - 1,
                                        NodeKind("module"), basename(child), mod_qname))
        end
    end

    # Track which file rows came from fresh parsing (need cache save).
    fresh_file_rows = Dict{String, Vector{CodeRow}}()

    # --- File nodes + their descendants (R6, R8, R10–R16) ---
    for d in sort(collect(keys(dir_to_files)))
        parent_id = isempty(d) ? codebase_id : NodeId(d)
        parent_qn = isempty(d) ? codebase_qname : child_qname(codebase_qname, basename(d))
        dir_files = sort(dir_to_files[d])
        depth     = isempty(d) ? 1 : 2

        for rel in dir_files
            # Determine sibling_order
            fi = if isempty(d)
                findfirst(==(rel), root_children)
            else
                findfirst(==(rel), dir_files)
            end

            current_hash  = hashes[rel]
            cached_hash   = _get_cached_hash(cache_db, rel)

            if !isnothing(cached_hash) && cached_hash == current_hash
                # Cache hit (R26): load code rows without re-parsing.
                cached = _load_file_rows_from_cache(cache_db, rel)
                if !isnothing(cached)
                    code_rows, _ = cached
                    code_rows[1].sibling_order = fi - 1  # update ordering
                    append!(all_rows, code_rows)
                    continue
                end
            end

            # Cache miss or stale: re-parse (R27).
            src       = buffer[rel]
            lang      = language_for_file(config, rel)
            file_rows = build_file_rows(
                src, lang, config, detail_threshold,
                NodeId(rel), FilePath(rel), parent_id, depth, parent_qn,
            )
            file_rows[1].sibling_order = fi - 1
            append!(all_rows, file_rows)
            fresh_file_rows[rel] = file_rows
        end
    end

    # Post-process: fill n_children for codebase and module rows
    id_to_children = Dict{String,Int}()
    for row in all_rows
        p = row.parent
        ismissing(p) && continue
        id_to_children[p] = get(id_to_children, p, 0) + 1
    end
    for row in all_rows
        if row.kind ∈ ("codebase", "module")
            row.n_children = get(id_to_children, row.id, 0)
        end
    end

    # --- Assemble DataFrames ---
    code_df = _rows_to_dataframe(all_rows)
    _assign_readme_summaries!(code_df, root_path, buffer)

    syms_df = DataFrame(node_id=String[], symbol=String[], kind=String[])

    db = CodeTreeDB(
        CodeTree(code_df),
        CodeSymbols(syms_df),
        root_path,
        config,
        detail_threshold,
        buffer,
        hashes,
    )
    extract_symbols!(db)
    _refresh_git_overlay!(db)

    # --- Persist cache (R24, R25) ---
    # Build a node_id → file lookup from the code DataFrame.
    code_df_raw = getfield(db.code, :_df)
    id_to_file  = Dict{String,String}(
        row.id => row.file
        for row in eachrow(code_df_raw)
        if !ismissing(row.file)
    )

    # Group symbol rows by file for freshly parsed files only. Unchanged files
    # keep their existing cached symbol rows.
    fresh_files = Set(keys(fresh_file_rows))
    sym_rows_by_file = Dict{String, Vector{SymbolRow}}()
    for sym_row in eachrow(getfield(db.symbols, :_df))
        f = get(id_to_file, sym_row.node_id, nothing)
        isnothing(f) && continue
        f ∈ fresh_files || continue
        push!(get!(sym_rows_by_file, f, SymbolRow[]),
              (node_id=sym_row.node_id, symbol=sym_row.symbol, kind=sym_row.kind))
    end

    # Save freshly parsed files to cache; unchanged files keep their cached code
    # and symbol rows and only refresh the file metadata.
    for rel in rel_files
        if haskey(fresh_file_rows, rel)
            sym_rows = get(sym_rows_by_file, rel, SymbolRow[])
            _save_file_rows!(cache_db, rel, hashes[rel], commit_hash,
                             fresh_file_rows[rel], sym_rows)
        else
            # Unchanged file: just refresh commit_hash metadata.
            _upsert_file!(cache_db, rel, hashes[rel], commit_hash)
        end
    end

    close(cache_db)
    return db
end

"""
    reload(db) -> CodeTreeDB

Re-index the codebase, detecting changed files and updating `db` in place.
Returns `db` for convenience.

Not yet implemented beyond a naive full reload.
"""
function reload(db::CodeTreeDB)::CodeTreeDB
    new_db = load(db.root, db.config; detail_threshold=db.detail_threshold)
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
# Reads from the in-memory buffer (R29) instead of disk.
function _assign_readme_summaries!(df::DataFrame, root_path::String,
                                    buffer::Dict{String,String})::Nothing
    for i in 1:nrow(df)
        kind = df[i, :kind]
        kind ∈ ("codebase", "module") || continue
        ismissing(df[i, :summary]) || continue  # already has a summary

        readme_rel = if kind == "codebase"
            "README.md"
        else
            mod_dir = String(df[i, :id])
            joinpath(mod_dir, "README.md")
        end
        readme_src = get(buffer, readme_rel, nothing)
        if !isnothing(readme_src)
            s = _readme_summary_from_string(readme_src)
            if !ismissing(s)
                df[i, :summary] = s
            end
        end
    end
    return nothing
end

function _struct_row(
    id::NodeId, parent::Union{NodeId,Missing}, depth::Int, sibling_order::Int,
    kind::NodeKind, name::String, qname::Union{QName,Missing}=missing,
)::CodeRow
    return CodeRow(
        id.val,
        _raw(parent),
        depth,
        sibling_order,
        kind.val,
        name,
        _raw(qname),
        missing,  # language
        missing,  # summary
        missing,  # source
        missing,  # signature
        missing,  # file
        missing,  # line_start
        missing,  # line_end
        missing,  # n_lines
        0,        # n_children
    )
end

function _rows_to_dataframe(rows::Vector{CodeRow})::DataFrame
    isempty(rows) && return DataFrame(
        id=String[], parent=Union{String,Missing}[], depth=Int[],
        sibling_order=Int[], kind=String[], name=String[],
        qname=Union{String,Missing}[], language=Union{String,Missing}[],
        summary=Union{String,Missing}[], source=Union{String,Missing}[],
        signature=Union{String,Missing}[], file=Union{String,Missing}[],
        line_start=Union{Int,Missing}[], line_end=Union{Int,Missing}[],
        n_lines=Union{Int,Missing}[], n_children=Int[],
        git_status=String[], git_has_staged=Bool[], git_has_unstaged=Bool[],
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
        git_status    = Vector{String}(undef, n),
        git_has_staged = Vector{Bool}(undef, n),
        git_has_unstaged = Vector{Bool}(undef, n),
    )

    for (i, row) in enumerate(rows)
        cols.id[i]            = row.id
        cols.parent[i]        = row.parent
        cols.depth[i]         = row.depth
        cols.sibling_order[i] = row.sibling_order
        cols.kind[i]          = row.kind
        cols.name[i]          = row.name
        cols.qname[i]         = row.qname
        cols.language[i]      = row.language
        cols.summary[i]       = row.summary
        cols.source[i]        = row.source
        cols.signature[i]     = row.signature
        cols.file[i]          = row.file
        cols.line_start[i]    = row.line_start
        cols.line_end[i]      = row.line_end
        cols.n_lines[i]       = row.n_lines
        cols.n_children[i]    = row.n_children
        cols.git_status[i]    = "clean"
        cols.git_has_staged[i] = false
        cols.git_has_unstaged[i] = false
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
        git_status    = cols.git_status,
        git_has_staged = cols.git_has_staged,
        git_has_unstaged = cols.git_has_unstaged,
    )
end
