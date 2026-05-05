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

    code_df = getfield(db.code,    :_df)
    syms_df = getfield(db.symbols, :_df)

    # --- Look up target node ---
    idx = findfirst(==(id_str), code_df.id)
    isnothing(idx) && throw(ArgumentError("Node '$id_str' not found in db.code"))

    file_rel = code_df[idx, :file]
    node_ls  = code_df[idx, :line_start]
    node_le  = code_df[idx, :line_end]
    ismissing(file_rel) && throw(ArgumentError("Node '$id_str' has no file association"))
    (ismissing(node_ls) || ismissing(node_le)) &&
        throw(ArgumentError("Node '$id_str' has no line range"))

    abs_path = joinpath(db.root, String(file_rel))

    # --- R30a: detect external modification ---
    disk_src  = try read(abs_path, String)
                catch e; throw(ErrorException("Cannot read '$file_rel': $e")) end
    disk_hash = bytes2hex(SHA.sha256(disk_src))
    if get(db._hashes, String(file_rel), disk_hash) != disk_hash
        _replace_file_in_db!(db, String(file_rel), disk_src)
        throw(ErrorException(
            "File '$(file_rel)' was modified externally; db has been refreshed. Please retry."))
    end

    # --- R31: splice new content into the buffer copy ---
    cur_src      = db._buffer[String(file_rel)]
    new_file_src = _splice_lines(cur_src, Int(node_ls), Int(node_le), new_src)

    # --- R32: re-index in memory (must succeed before touching DataFrames) ---
    new_code_rows = _build_file_rows_for_update(db, String(file_rel), new_file_src)
    new_sym_rows  = _extract_symbols_for_file(db, String(file_rel), new_file_src, new_code_rows)

    # --- R35: save pre-call state for potential rollback ---
    old_code_df  = copy(code_df)
    old_syms_df  = copy(syms_df)
    old_buf      = db._buffer[String(file_rel)]
    old_hash     = db._hashes[String(file_rel)]

    # --- R33: update db.code ---
    file_mask        = [isequal(f, String(file_rel)) for f in code_df.file]
    old_file_node_ids = Set(code_df.id[file_mask])
    deleteat!(code_df, findall(file_mask))
    append!(code_df, _rows_to_dataframe(new_code_rows))

    # --- R33a: replace symbol rows for this file ---
    sym_mask = [s in old_file_node_ids for s in syms_df.node_id]
    deleteat!(syms_df, findall(sym_mask))
    new_syms = DataFrame(node_id=String[], symbol=String[], kind=String[])
    for s in new_sym_rows
        push!(new_syms, (node_id=s.node_id, symbol=s.symbol, kind=s.kind))
    end
    append!(syms_df, new_syms)

    # --- R34: write to disk and update cache ---
    new_hash = bytes2hex(SHA.sha256(new_file_src))
    try
        db._buffer[String(file_rel)] = new_file_src
        db._hashes[String(file_rel)] = new_hash
        write(abs_path, new_file_src)
        _update_cache_for_file!(db, String(file_rel), new_file_src, new_hash, new_code_rows, new_sym_rows)
    catch e
        # R35: rollback all in-memory state
        empty!(code_df); append!(code_df, old_code_df)
        empty!(syms_df); append!(syms_df, old_syms_df)
        db._buffer[String(file_rel)] = old_buf
        db._hashes[String(file_rel)] = old_hash
        rethrow(e)
    end

    return nothing
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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
    file_rel::String,
    new_src::String,
)::Vector{Dict{Symbol,Any}}
    code_df = getfield(db.code, :_df)
    fidx = findfirst(==(file_rel), code_df.id)
    isnothing(fidx) && throw(ErrorException("File node '$file_rel' not in db.code"))

    parent_id     = code_df[fidx, :parent]
    depth         = code_df[fidx, :depth]
    sibling_order = code_df[fidx, :sibling_order]

    lang = language_for_file(db.config, file_rel)
    rows = build_file_rows(new_src, lang, db.config, 30,
                           file_rel, file_rel, parent_id, depth)
    rows[1][:sibling_order] = sibling_order
    return rows
end

# Extract symbol rows for a single non-Markdown file given fresh code rows.
# Mirrors the per-file logic inside extract_symbols! (Pass 1).
function _extract_symbols_for_file(
    db::CodeTreeDB,
    file_rel::String,
    new_src::String,
    new_code_rows::Vector{Dict{Symbol,Any}},
)::Vector{NamedTuple}
    lang_val = language_for_file(db.config, file_rel)
    (ismissing(lang_val) || lang_val == "markdown") && return NamedTuple[]
    lang = lang_val
    lang ∉ ("cpp", "julia") && return NamedTuple[]

    lang_entry = get(db.config.languages, lang, nothing)
    isnothing(lang_entry) && return NamedTuple[]

    tree = parse_source(new_src, lang)
    isnothing(tree) && return NamedTuple[]
    root_node = TreeSitter.root(tree)

    call_caps = _run_queries(lang_entry.call_patterns,       new_src, root_node, lang)
    def_caps  = _run_queries(lang_entry.definition_patterns, new_src, root_node, lang)
    ref_caps  = _run_ident_query(new_src, root_node, lang)

    new_code_df = _rows_to_dataframe(new_code_rows)
    file_leaves = filter(r -> r.n_children == 0, new_code_df)

    result = NamedTuple{(:node_id, :symbol, :kind), Tuple{String,String,String}}[]
    seen   = Set{Tuple{String,String,String}}()

    for lrow in eachrow(file_leaves)
        ismissing(lrow.line_start) && continue
        ls0 = lrow.line_start - 1
        le0 = lrow.line_end   - 1
        scope_ls0, scope_le0 = _enclosing_scope_range(lrow, new_code_df)

        calls    = Set{String}(_caps_in(call_caps, ls0, le0))
        loc_defs = Set{String}(_caps_in(def_caps,  scope_ls0, scope_le0))
        all_refs = Set{String}(_caps_in(ref_caps,  ls0, le0))
        var_refs = setdiff(all_refs, loc_defs, calls)

        nid = lrow.id
        for (names, kind) in ((calls, "call"), (var_refs, "var_ref"))
            for name in names
                key = (nid, name, kind)
                key ∈ seen && continue
                push!(seen, key)
                push!(result, (node_id=nid, symbol=name, kind=kind))
            end
        end
    end
    return result
end

# Re-index `file_rel` from `new_src` and update db in place (used by R30a).
function _replace_file_in_db!(db::CodeTreeDB, file_rel::String, new_src::String)
    code_df = getfield(db.code,    :_df)
    syms_df = getfield(db.symbols, :_df)

    new_code_rows = _build_file_rows_for_update(db, file_rel, new_src)
    new_sym_rows  = _extract_symbols_for_file(db, file_rel, new_src, new_code_rows)

    file_mask         = [isequal(f, file_rel) for f in code_df.file]
    old_file_node_ids = Set(code_df.id[file_mask])

    deleteat!(code_df, findall(file_mask))
    append!(code_df, _rows_to_dataframe(new_code_rows))

    sym_mask = [s in old_file_node_ids for s in syms_df.node_id]
    deleteat!(syms_df, findall(sym_mask))
    for s in new_sym_rows
        push!(syms_df, (node_id=s.node_id, symbol=s.symbol, kind=s.kind))
    end

    new_hash = bytes2hex(SHA.sha256(new_src))
    db._buffer[file_rel] = new_src
    db._hashes[file_rel] = new_hash
end

# Write updated cache entries for a single file after a successful update_source.
function _update_cache_for_file!(
    db::CodeTreeDB,
    file_rel::String,
    new_file_src::String,
    new_hash::String,
    new_code_rows::Vector{Dict{Symbol,Any}},
    new_sym_rows,
)
    cache_db = _open_or_create_cache(db.root)
    commit_hash = _current_commit_hash(db.root)
    try
        _save_file_rows!(cache_db, file_rel, new_hash, commit_hash,
                         new_code_rows, new_sym_rows)
    finally
        close(cache_db)
    end
end
