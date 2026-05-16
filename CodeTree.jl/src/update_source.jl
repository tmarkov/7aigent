# update_source() — R30–R35.
#
# This is the sole authorized mutation path (R30). It:
#   1. Detects external file changes and re-indexes if needed (R30a)
#   2. Splices new_source over the node's line range (R31)
#   3. Re-indexes in memory; only updates DataFrames on success (R32)
#   4. Updates db.code and db.symbols atomically before disk write (R33, R33a)
#   5. Writes to disk and updates the SQLite cache (R34)
#   6. Rolls back all in-memory state if the disk write fails (R35)

"""
    get_source(db, id) -> String

Return the current source text for node `id` from the in-memory buffer.

For leaf nodes this matches the `source` column. For non-leaf nodes, whose
`source` column is `missing`, this reconstructs the node span on demand using
the node's `(line_start, line_end)` range.
"""
function get_source(
    db::CodeTreeDB,
    id::AbstractString,
)::String
    _, file_rel, node_ls, node_le = _lookup_node_span(db, String(id))
    cur_src = db._buffer[file_rel]
    return _slice_lines(cur_src, Int(node_ls), Int(node_le))
end

"""
    update_source(db, id, new_source)

Replace the source of node `id` in `db` with `new_source`.

`new_source` must cover the full span of the node (from `line_start` to
`line_end`).  Raises an error if the target file was modified externally since
the last `load`; in that case `db` is refreshed to reflect the on-disk state.
"""
function update_source(
    db::CodeTreeDB,
    id::AbstractString,
    new_source::AbstractString,
)::Nothing
    id_str  = String(id)
    new_src = String(new_source)

    code_df = getfield(db.code, :_df)
    syms_df = getfield(db.symbols, :_df)
    _, file_rel, node_ls, node_le = _lookup_node_span(db, id_str)

    file_rel_typed = FilePath(file_rel)
    abs_path = joinpath(db.root, file_rel)

    # --- R30a: detect external modification ---
    disk_src  = try read(abs_path, String)
                catch e; throw(ErrorException("Cannot read '$file_rel': $e")) end
    disk_hash = bytes2hex(SHA.sha256(disk_src))
    if get(db._hashes, file_rel, disk_hash) != disk_hash
        _replace_file_in_db!(db, file_rel_typed, disk_src)
        throw(ErrorException(
            "File '$(file_rel)' was modified externally; db has been refreshed. Please retry."))
    end

    # R30b: verify the current node span against the buffer-backed accessor so
    # leaf and non-leaf nodes share the same edit path.
    current_node_src = get_source(db, id_str)
    disk_node_src = _slice_lines(disk_src, Int(node_ls), Int(node_le))
    if disk_node_src != current_node_src
        _replace_file_in_db!(db, file_rel_typed, disk_src)
        throw(ErrorException(
            "Node '$id_str' no longer matches on-disk content; db has been refreshed. Please retry."))
    end

    # --- R31: splice new content into the buffer copy ---
    cur_src      = db._buffer[file_rel]
    new_file_src = _splice_lines(cur_src, Int(node_ls), Int(node_le), new_src)

    # --- R32: re-index in memory (must succeed before touching DataFrames) ---
    new_code_rows = _build_file_rows_for_update(db, file_rel_typed, new_file_src)
    new_sym_rows  = _extract_symbols_for_file(db, file_rel_typed, new_file_src, new_code_rows)

    # --- R35: save pre-call state for potential rollback ---
    old_code_df  = copy(code_df)
    old_syms_df  = copy(syms_df)
    old_buf      = db._buffer[file_rel]
    old_hash     = db._hashes[file_rel]
    old_summary_baseline = copy(getfield(db.code, :_summary_baseline))
    old_summary_overrides = copy(getfield(db.code, :_summary_overrides))

    # --- R33 + R33a: replace this file's code and symbol rows in memory ---
    _replace_file_rows_preserving_summaries!(db, file_rel_typed, new_code_rows, new_sym_rows)

    # --- R34: write to disk and update cache ---
    new_hash = bytes2hex(SHA.sha256(new_file_src))
    try
        db._buffer[file_rel] = new_file_src
        db._hashes[file_rel] = new_hash
        write(abs_path, new_file_src)
        _update_cache_for_file!(db, file_rel_typed, new_file_src, new_hash, new_code_rows, new_sym_rows)
    catch e
        # R35: rollback all in-memory state
        empty!(code_df); append!(code_df, old_code_df)
        empty!(syms_df); append!(syms_df, old_syms_df)
        db._buffer[file_rel] = old_buf
        db._hashes[file_rel] = old_hash
        empty!(getfield(db.code, :_summary_baseline))
        merge!(getfield(db.code, :_summary_baseline), old_summary_baseline)
        empty!(getfield(db.code, :_summary_overrides))
        merge!(getfield(db.code, :_summary_overrides), old_summary_overrides)
        rethrow(e)
    end

    return nothing
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function _lookup_node_span(
    db::CodeTreeDB,
    id_str::String,
)::Tuple{Int,String,Int,Int}
    code_df = getfield(db.code, :_df)
    idx = findfirst(==(id_str), code_df.id)
    isnothing(idx) && throw(ArgumentError("Node '$id_str' not found in db.code"))

    file_rel = code_df[idx, :file]
    node_ls  = code_df[idx, :line_start]
    node_le  = code_df[idx, :line_end]
    ismissing(file_rel) && throw(ArgumentError("Node '$id_str' has no file association"))
    (ismissing(node_ls) || ismissing(node_le)) &&
        throw(ArgumentError("Node '$id_str' has no line range"))

    return (idx, file_rel, Int(node_ls), Int(node_le))
end

function _slice_lines(src::String, ls::Int, le::Int)::String
    lines = split(src, '\n')
    if !isempty(lines) && isempty(lines[end])
        pop!(lines)
    end

    if isempty(lines)
        (ls == 1 && le == 1) || throw(ArgumentError("Invalid line span $ls:$le for empty source"))
        return ""
    end

    ls < 1 && throw(ArgumentError("line_start must be >= 1"))
    le < ls && throw(ArgumentError("line_end must be >= line_start"))
    le <= length(lines) || throw(ArgumentError("line_end $le exceeds source length $(length(lines))"))
    return join(lines[ls:le], '\n')
end

# Replace lines ls..le (1-indexed, inclusive) of `src` with `new_src`.
function _splice_lines(src::String, ls::Int, le::Int, new_src::String)::String
    parts     = split(src,     '\n'; keepempty=true)
    new_parts = split(new_src, '\n'; keepempty=true)
    before = parts[1:ls-1]
    after  = parts[le+1:end]
    # Drop trailing "" from new_parts if new_src ends with '\n' (the boundary
    # newline is implicit in how we join with after).
    if endswith(new_src, '\n') && !isempty(new_parts) && new_parts[end] == ""
        new_parts = new_parts[1:end-1]
    end
    return join(vcat(before, new_parts, after), '\n')
end

# Build fresh file rows for `file_rel` using `new_src`, preserving the file
# node's existing parent, depth, and sibling_order from db.code.
function _build_file_rows_for_update(
    db::CodeTreeDB,
    file_rel::FilePath,
    new_src::String,
)::Vector{CodeRow}
    code_df = getfield(db.code, :_df)
    fidx = findfirst(==(file_rel.val), code_df.id)
    isnothing(fidx) && throw(ErrorException("File node '$(file_rel.val)' not in db.code"))

    parent_id     = code_df[fidx, :parent]
    depth         = code_df[fidx, :depth]
    sibling_order = code_df[fidx, :sibling_order]

    # Derive parent_qname from the parent node's qname (for qname population).
    parent_qname = QName("")
    if !ismissing(parent_id)
        pidx = findfirst(==(parent_id), code_df.id)
        if !isnothing(pidx) && !ismissing(code_df[pidx, :qname])
            parent_qname = QName(code_df[pidx, :qname])
        end
    end

    lang = language_for_file(db.config, file_rel.val)
    rows = build_file_rows(new_src, lang, db.config, db.detail_threshold,
                           NodeId(file_rel.val), file_rel, NodeId(parent_id),
                           depth, parent_qname)
    rows[1].sibling_order = sibling_order
    return rows
end

# Extract symbol rows for a single file given fresh code rows.
# Delegates to _extract_file_symbols (symbols.jl) for the per-file logic.
# known_names is built from the existing db.code (R21c).
function _extract_symbols_for_file(
    db::CodeTreeDB,
    file_rel::FilePath,
    new_src::String,
    new_code_rows::Vector{CodeRow},
)::Vector{SymbolRow}
    lang_val = language_for_file(db.config, file_rel.val)
    ismissing(lang_val) && return SymbolRow[]

    lang_entry = get(db.config.languages, lang_val, nothing)
    isnothing(lang_entry) && return SymbolRow[]

    new_code_df = _rows_to_dataframe(new_code_rows)
    file_leaves = filter(r -> r.n_children == 0, new_code_df)
    isempty(file_leaves) && return SymbolRow[]

    # R21c: known_names from non-Markdown code node names in the current db.
    code_df = getfield(db.code, :_df)
    non_md = filter(r -> !ismissing(r.language) && r.language != "markdown", code_df)
    known_names = Set{String}(skipmissing(non_md.name))

    raw = _extract_file_symbols(new_src, lang_val, lang_entry, file_leaves,
                                  new_code_df, known_names, db.config)

    # Deduplicate before returning.
    seen   = Set{Tuple{String,String,String}}()
    result = SymbolRow[]
    for r in raw
        key = (r.node_id, r.symbol, r.kind)
        key ∈ seen && continue
        push!(seen, key)
        push!(result, r)
    end
    return result
end

function _replace_file_rows!(
    code_df::DataFrame,
    syms_df::DataFrame,
    file_rel::FilePath,
    new_code_rows::Vector{CodeRow},
    new_sym_rows::Vector{SymbolRow},
)::Nothing
    file_mask = [isequal(f, file_rel.val) for f in code_df.file]
    old_file_node_ids = Set(code_df.id[file_mask])

    deleteat!(code_df, findall(file_mask))
    append!(code_df, _rows_to_dataframe(new_code_rows))

    sym_mask = [s in old_file_node_ids for s in syms_df.node_id]
    deleteat!(syms_df, findall(sym_mask))
    for s in new_sym_rows
        push!(syms_df, (node_id=s.node_id, symbol=s.symbol, kind=s.kind))
    end
    return nothing
end

function _replace_file_rows_preserving_summaries!(
    db::CodeTreeDB,
    file_rel::FilePath,
    new_code_rows::Vector{CodeRow},
    new_sym_rows::Vector{SymbolRow},
)::Nothing
    code_df = getfield(db.code, :_df)
    syms_df = getfield(db.symbols, :_df)
    old_file_node_ids = _file_node_ids(code_df, file_rel)
    preserved_overrides = Dict{String,Union{String,Missing}}()
    for id in old_file_node_ids
        overrides = getfield(db.code, :_summary_overrides)
        haskey(overrides, id) || continue
        preserved_overrides[id] = overrides[id]
    end

    _replace_file_rows!(code_df, syms_df, file_rel, new_code_rows, new_sym_rows)
    _restore_file_summary_overrides!(db.code, old_file_node_ids, new_code_rows, preserved_overrides)
    return nothing
end

function _file_node_ids(code_df::DataFrame, file_rel::FilePath)::Set{String}
    file_mask = [isequal(f, file_rel.val) for f in code_df.file]
    return Set(string.(code_df.id[file_mask]))
end

function _restore_file_summary_overrides!(
    code_tree::CodeTree,
    old_file_node_ids::Set{String},
    new_code_rows::Vector{CodeRow},
    preserved_overrides::Dict{String,Union{String,Missing}},
)::Nothing
    baseline = getfield(code_tree, :_summary_baseline)
    overrides = getfield(code_tree, :_summary_overrides)
    for id in old_file_node_ids
        delete!(baseline, id)
        delete!(overrides, id)
    end
    for row in new_code_rows
        baseline[row.id] = row.summary
    end

    code_df = getfield(code_tree, :_df)
    for row in eachrow(code_df)
        haskey(preserved_overrides, row.id) || continue
        row.summary = preserved_overrides[row.id]
    end
    _recompute_summary_overrides!(code_tree)
    return nothing
end

function _replace_file_in_db!(db::CodeTreeDB, file_rel::FilePath, new_src::String)::Nothing
    code_df = getfield(db.code,    :_df)
    syms_df = getfield(db.symbols, :_df)

    new_code_rows = _build_file_rows_for_update(db, file_rel, new_src)
    new_sym_rows  = _extract_symbols_for_file(db, file_rel, new_src, new_code_rows)

    _replace_file_rows_preserving_summaries!(db, file_rel, new_code_rows, new_sym_rows)

    new_hash = bytes2hex(SHA.sha256(new_src))
    db._buffer[file_rel.val] = new_src
    db._hashes[file_rel.val] = new_hash
    return nothing
end

# Write updated cache entries for a single file after a successful update_source.
function _update_cache_for_file!(
    db::CodeTreeDB,
    file_rel::FilePath,
    new_file_src::String,
    new_hash::String,
    new_code_rows::Vector{CodeRow},
    new_sym_rows::Vector{SymbolRow},
)::Nothing
    cache_db = _open_or_create_cache(db.root)
    commit_hash = _current_commit_hash(db.root)
    try
        _save_file_rows!(cache_db, file_rel.val, new_hash, commit_hash,
                         new_code_rows, new_sym_rows)
    finally
        close(cache_db)
    end
    return nothing
end
