# update_source!() — R30–R38.
#
# This is the sole authorized mutation path (R30). It:
#   1. Searches for pattern in the node's source (R37 for String, Base.replace for Regex)
#   2. Throws ArgumentError on zero matches (R38)
#   3. Warns with match locations on over-match (R38)
#   4. Delegates to _update_source! for R30a–R35
#   5. Prints a unified diff on success (R36)
#
# _update_source!(db, id, new_source) — internal core mutation (R30a–R35):
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
    update_source!(db, id, pattern => repl; count=1)

Replace occurrences of `pattern` in the source of node `id` with `repl`,
re-index the changed file, and print a unified diff to stdout.

`pattern` may be a `String` or a `Regex`:
- `String`: matching is indentation-agnostic (R37) — the pattern is dedented
  before searching, and the replacement is re-indented to match the detected
  offset in the source.
- `Regex`: uses `Base.replace` semantics with no indentation normalisation.

`count` is the maximum number of occurrences to replace (default 1). Throws
`ArgumentError` if the pattern matches zero times. Prints a warning naming all
match locations if the actual count exceeds `count`.
"""
function update_source!(
    db::CodeTreeDB,
    id::AbstractString,
    pair::Pair;
    count::Int = 1,
)::Nothing
    id_str  = String(id)
    pattern = pair.first
    repl    = pair.second

    node_src = get_source(db, id_str)

    # R37/R38: find matches, validate count, build new node source
    new_node_src, file_rel = _apply_pattern_substitution(
        db, id_str, node_src, pattern, repl, count)

    # Delegate to internal mutation (R30a–R35)
    old_file_src = db._buffer[file_rel]
    _update_source!(db, id_str, new_node_src)
    new_file_src = db._buffer[file_rel]

    # R36: print unified diff of the changed file
    _print_unified_diff(file_rel, old_file_src, new_file_src)
    return nothing
end

"""
    _update_source!(db, id, new_source)

Internal mutation path. Replace the source of node `id` in `db` with
`new_source`, carrying out external-change detection (R30a), in-memory
re-indexing (R31–R33), disk write, cache update (R34), and rollback on
failure (R35).
"""
function _update_source!(
    db::CodeTreeDB,
    id::AbstractString,
    new_source::AbstractString,
)::Nothing
    id_str  = String(id)
    new_src = String(new_source)

    code_df = getfield(db.code, :_df)
    code_df = getfield(db.code, :_df)
    syms_df = getfield(db.symbols, :_df)
    _, file_rel, node_ls, node_le = _lookup_node_span(db, id_str)

    file_rel_typed = FilePath(file_rel)
    abs_path = joinpath(db.root, file_rel)

    # --- R30a: detect external modification ---
    disk_src  = try
        read(abs_path, String)
    catch e
        _is_file_read_failure(e) || rethrow()
        throw(ErrorException("Cannot read '$file_rel': $e"))
    end
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
        _refresh_git_overlay!(db)
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
# Internal helpers: pattern substitution, indentation-agnostic matching,
# unified diff output (R36, R37, R38)
# ---------------------------------------------------------------------------

# R38 + R37: apply the pattern substitution to node_src, enforcing zero-match
# error and over-match warning. Returns (new_node_src, file_rel).
function _apply_pattern_substitution(
    db::CodeTreeDB,
    id_str::String,
    node_src::String,
    pattern::AbstractString,
    repl::AbstractString,
    count::Int,
)::Tuple{String,String}
    pat_str = String(pattern)
    rep_str = String(repl)

    # R37: indentation-agnostic search for String patterns.
    dedented_pat = _dedent(pat_str)
    matches = _find_indentation_agnostic_matches(node_src, dedented_pat)

    if isempty(matches)
        throw(ArgumentError("update_source!: pattern not found in $(id_str)"))
    end

    if length(matches) > count
        _warn_over_matches_string(id_str, matches, node_src, count)
    end

    new_node_src = _apply_indentation_agnostic_replace(
        node_src, dedented_pat, rep_str, matches, count)

    _, file_rel, _, _ = _lookup_node_span(db, id_str)
    return new_node_src, file_rel
end

function _apply_pattern_substitution(
    db::CodeTreeDB,
    id_str::String,
    node_src::String,
    pattern::Regex,
    repl::AbstractString,
    count::Int,
)::Tuple{String,String}
    rep_str = String(repl)

    matches = collect(eachmatch(pattern, node_src))
    if isempty(matches)
        throw(ArgumentError("update_source!: pattern not found in $(id_str)"))
    end

    if length(matches) > count
        _warn_over_matches_regex(id_str, matches, node_src, count)
    end

    new_node_src = replace(node_src, pattern => rep_str; count=count)

    _, file_rel, _, _ = _lookup_node_span(db, id_str)
    return new_node_src, file_rel
end

# Strip minimum common leading whitespace from all non-blank lines.
function _dedent(s::String)::String
    lines = split(s, '\n')
    non_blank = filter(l -> !isempty(strip(l)), lines)
    isempty(non_blank) && return s
    min_indent = minimum(length(l) - length(lstrip(l)) for l in non_blank)
    min_indent == 0 && return s
    prefix = ' '^min_indent
    result = map(lines) do l
        isempty(strip(l)) ? l : (startswith(l, prefix) ? l[min_indent+1:end] : l)
    end
    return join(result, '\n')
end

# Find all positions where the dedented pattern occurs in src with any
# consistent indentation.  Returns a vector of (line_index, indent_spaces)
# pairs, where line_index is 1-based into split(src, '\n').
function _find_indentation_agnostic_matches(
    src::String,
    dedented_pat::String,
)::Vector{Tuple{Int,Int}}
    src_lines = split(src, '\n')
    pat_lines = split(dedented_pat, '\n')
    n_src = length(src_lines)
    n_pat = length(pat_lines)
    results = Tuple{Int,Int}[]

    for start_i in 1:(n_src - n_pat + 1)
        offset = -1
        matched = true
        for (j, pl) in enumerate(pat_lines)
            sl = src_lines[start_i + j - 1]
            pl_is_blank = isempty(strip(pl))

            if pl_is_blank
                if !isempty(strip(sl))
                    matched = false; break
                end
            else
                sl_indent = length(sl) - length(lstrip(sl))
                if offset == -1
                    offset = sl_indent
                end
                expected = ' '^offset * pl
                if sl != expected
                    matched = false; break
                end
            end
        end
        if matched && offset >= 0
            push!(results, (start_i, offset))
        end
    end
    return results
end

# Apply indentation-agnostic replacement for the first `count` matches.
# matches is a vector of (line_index, indent) from _find_indentation_agnostic_matches.
function _apply_indentation_agnostic_replace(
    src::String,
    dedented_pat::String,
    repl::String,
    matches::Vector{Tuple{Int,Int}},
    count::Int,
)::String
    pat_lines = split(dedented_pat, '\n')
    n_pat_lines = length(pat_lines)
    result_lines = split(src, '\n')

    n_to_replace = min(count, length(matches))
    # Work backwards to preserve line indices for earlier matches.
    for i in n_to_replace:-1:1
        ls, indent = matches[i]
        le = ls + n_pat_lines - 1

        dedented_repl = _dedent(repl)
        repl_lines = split(dedented_repl, '\n')
        re_indented = map(repl_lines) do rl
            isempty(strip(rl)) ? rl : ' '^indent * rl
        end

        splice!(result_lines, ls:le, re_indented)
    end
    return join(result_lines, '\n')
end

# Warn about over-matches. For :string patterns uses line numbers; for :regex
# uses line + char range within the line.
function _warn_over_matches_string(
    id_str::String,
    matches::Vector{Tuple{Int,Int}},
    node_src::String,
    count::Int,
)::Nothing
    src_lines = split(node_src, '\n')
    # Add node-level line offset to get correct absolute line numbers within
    # the node source (matches are already 1-based line indices).
    println("Warning: pattern matched $(length(matches)) times in $(id_str) " *
            "(count=$(count)); replacing only the first $(count).")
    println("Match locations:")
    for (ln, _) in matches
        println("  line $(ln)")
    end
    return nothing
end

function _warn_over_matches_regex(
    id_str::String,
    matches::Vector{RegexMatch},
    node_src::String,
    count::Int,
)::Nothing
    src_lines = split(node_src, '\n')
    println("Warning: pattern matched $(length(matches)) times in $(id_str) " *
            "(count=$(count)); replacing only the first $(count).")
    println("Match locations:")
    for m in matches
        ln, col_start = _byte_offset_to_line_col(src_lines, m.offset)
        col_end = col_start + ncodeunits(m.match) - 1
        println("  line $(ln), chars $(col_start):$(col_end)")
    end
    return nothing
end

function _byte_offset_to_line_col(
    src_lines::Vector{<:AbstractString},
    byte_start::Int,
)::Tuple{Int,Int}
    acc = 0
    for (i, l) in enumerate(src_lines)
        line_end = acc + ncodeunits(l) + 1
        if line_end >= byte_start
            col = byte_start - acc
            return (i, col)
        end
        acc = line_end
    end
    return (length(src_lines), 1)
end

# ---------------------------------------------------------------------------
# R36: Unified diff output
# ---------------------------------------------------------------------------

# Print a standard unified diff (--- a/..., +++ b/..., @@ hunks, 3-line
# context) of old_src → new_src for the given file path.
function _print_unified_diff(file_rel::String, old_src::String, new_src::String)::Nothing
    old_lines = split(old_src, '\n')
    new_lines = split(new_src, '\n')

    hunks = _compute_diff_hunks(old_lines, new_lines; context=3)
    isempty(hunks) && return nothing

    println("--- a/$(file_rel)")
    println("+++ b/$(file_rel)")
    for hunk in hunks
        _print_hunk(hunk)
    end
    return nothing
end

struct DiffHunk
    old_start::Int
    old_count::Int
    new_start::Int
    new_count::Int
    lines::Vector{String}   # each line prefixed with ' ', '-', or '+'
end

# Compute an edit script using a simple LCS-based diff, then group into hunks
# with `context` lines of surrounding context.
function _compute_diff_hunks(
    old_lines::Vector{<:AbstractString},
    new_lines::Vector{<:AbstractString};
    context::Int = 3,
)::Vector{DiffHunk}
    ops = _diff_ops(old_lines, new_lines)  # vector of (' ', '-', '+') with line text
    isempty(ops) && return DiffHunk[]

    # Group ops into hunks: collect changed regions ± context lines.
    n = length(ops)
    hunks = DiffHunk[]
    i = 1
    while i <= n
        # Skip equal ops until we find a change.
        if ops[i][1] == ' '
            i += 1
            continue
        end
        # Found a change; back up `context` lines for pre-context.
        hunk_start = max(1, i - context)
        # Advance past all changes + context.
        j = i
        while j <= n
            if ops[j][1] != ' '
                j += 1
            elseif j + context <= n && any(ops[k][1] != ' ' for k in (j+1):min(j+context, n))
                j += 1
            else
                j = min(j + context, n) + 1
                break
            end
        end
        hunk_end = j - 1

        hunk_ops = ops[hunk_start:hunk_end]
        old_s = count(op -> op[1] != '+', ops[1:hunk_start-1]) + 1
        new_s = count(op -> op[1] != '-', ops[1:hunk_start-1]) + 1
        old_c = count(op -> op[1] != '+', hunk_ops)
        new_c = count(op -> op[1] != '-', hunk_ops)
        lines = [op[1] * op[2] for op in hunk_ops]
        push!(hunks, DiffHunk(old_s, old_c, new_s, new_c, lines))
        i = hunk_end + 1
    end
    return hunks
end

function _print_hunk(h::DiffHunk)::Nothing
    old_range = h.old_count == 1 ? "$(h.old_start)" : "$(h.old_start),$(h.old_count)"
    new_range = h.new_count == 1 ? "$(h.new_start)" : "$(h.new_start),$(h.new_count)"
    println("@@ -$(old_range) +$(new_range) @@")
    for l in h.lines
        println(l)
    end
    return nothing
end

# Produce a sequence of (op, line_text) pairs where op ∈ {' ', '-', '+'}.
# Uses the Myers/Wagner-Fischer LCS to compute the shortest edit script.
function _diff_ops(
    old_lines::Vector{<:AbstractString},
    new_lines::Vector{<:AbstractString},
)::Vector{Tuple{Char,String}}
    m, n = length(old_lines), length(new_lines)
    # Build LCS table.
    dp = zeros(Int, m + 1, n + 1)
    for i in m:-1:1, j in n:-1:1
        if old_lines[i] == new_lines[j]
            dp[i, j] = 1 + dp[i+1, j+1]
        else
            dp[i, j] = max(dp[i+1, j], dp[i, j+1])
        end
    end
    # Backtrack to produce edit ops.
    ops = Tuple{Char,String}[]
    i, j = 1, 1
    while i <= m || j <= n
        if i <= m && j <= n && old_lines[i] == new_lines[j]
            push!(ops, (' ', old_lines[i]))
            i += 1; j += 1
        elseif j <= n && (i > m || dp[i, j+1] >= dp[i+1, j])
            push!(ops, ('+', new_lines[j]))
            j += 1
        else
            push!(ops, ('-', old_lines[i]))
            i += 1
        end
    end
    return ops
end

# ---------------------------------------------------------------------------
# Internal helpers: node lookup, line splicing
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
# known_names is built from declaration-like rows in the existing db.code (R21c).
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

    # R21c: known_names from declaration-like non-Markdown code node names.
    code_df = getfield(db.code, :_df)
    known_names = _declaration_like_known_names(code_df)

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
    _refresh_git_overlay!(db)
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
