# Tree builder — implements R10–R16.
# Converts a tree-sitter parse tree into a flat list of db.code row dicts.

# ---------------------------------------------------------------------------
# Internal span tracker
# ---------------------------------------------------------------------------

mutable struct _Span
    kind::String
    name::String
    ls::Int                           # 1-indexed line_start (adjusted)
    le::Int                           # 1-indexed line_end (adjusted)
    ts_node::Union{TreeSitter.Node,Nothing}  # nothing for chunk/comment nodes
    summary_src::Union{String,Nothing}       # raw source for summary extraction
end

# ---------------------------------------------------------------------------
# Name extraction — driven by entry.name_patterns (tree-sitter queries)
# ---------------------------------------------------------------------------

"""
    _query_name(entry, node, src) -> Union{String, Nothing}

Run the `entry.name_patterns` queries against `node`'s subtree and return
the text of the `@name` capture with the earliest (row, column) position
among captures within the first five lines of `node`. Returns `nothing` when
no patterns match or when `entry.grammar_symbol` is `nothing`.
"""
function _query_name(
    entry::LanguageEntry,
    node::TreeSitter.Node,
    src::String,
)::Union{String, Nothing}
    isnothing(entry.grammar_symbol) && return nothing
    isempty(entry.name_patterns)   && return nothing

    lang_obj   = Language(entry.grammar_symbol)
    node_start = Int(TreeSitter.API.ts_node_start_point(node.ptr).row)

    best_text = nothing
    best_row  = typemax(Int)
    best_col  = typemax(Int)

    for pat in entry.name_patterns
        q = try
            Query(lang_obj, pat)
        catch e
            _is_query_compile_failure(e) || rethrow()
            continue
        end
        cursor = TreeSitter.QueryCursor()
        TreeSitter.exec(cursor, q, node)
        while true
            m = TreeSitter.next_match(cursor)
            m === nothing && break
            for i in 1:TreeSitter.capture_count(m)
                raw_cap  = unsafe_load(m.obj.captures, i)
                cap_node = TreeSitter.Node(raw_cap.node)
                pt = TreeSitter.API.ts_node_start_point(cap_node.ptr)
                rs = Int(pt.row)
                cs = Int(pt.column)
                # Only consider captures in the first few lines (name is in the header)
                rs > node_start + 4 && continue
                if rs < best_row || (rs == best_row && cs < best_col)
                    best_row  = rs
                    best_col  = cs
                    best_text = String(TreeSitter.slice(src, cap_node))
                end
            end
        end
    end

    return best_text
end

# ---------------------------------------------------------------------------
# Body finding — driven by entry.body_fields / entry.body_node_types
# ---------------------------------------------------------------------------

"""
    _find_body(entry, node) -> TreeSitter.Node

Return the body sub-node to recurse into for `node`, using the field names
in `entry.body_fields` first, then the node types in `entry.body_node_types`.
Falls back to `node` itself when nothing matches.
"""
function _find_body(entry::LanguageEntry, node::TreeSitter.Node)::TreeSitter.Node
    for field in entry.body_fields
        n = TreeSitter.child(node, field)
        !TreeSitter.is_null(n) && return n
    end
    for gc in TreeSitter.named_children(node)
        TreeSitter.node_type(gc) ∈ entry.body_node_types && return gc
    end
    return node
end

# ---------------------------------------------------------------------------
# Gap helper: is a slice of source lines entirely blank/whitespace?
# ---------------------------------------------------------------------------

function _all_blank(src_lines::Vector{<:AbstractString}, from::Int, to::Int)::Bool
    for i in max(1, from):min(length(src_lines), to)
        isempty(strip(src_lines[i])) || return false
    end
    return true
end

# ---------------------------------------------------------------------------
# Main recursive builder
# ---------------------------------------------------------------------------

"""
    _build_level(...) -> Vector{CodeRow}

Build db.code rows for all visible descendants of `parent_ts_node`,
applying R10–R16 (landmark/detail filtering, spanning, comment absorption,
chunk gap-filling, sibling ordering).

Returns an empty vector when the parent has no visible children (leaf node).
"""
function _build_level(
    parent_ts_node::TreeSitter.Node,
    src::String,
    src_lines::Vector{<:AbstractString},
    entry::LanguageEntry,
    language::String,
    config::LanguageConfig,
    detail_threshold::Int,
    parent_id::NodeId,
    file_path::FilePath,
    depth::Int,
    parent_ls::Int,
    parent_le::Int,
    parent_qname::QName=QName(""),
)::Vector{CodeRow}

    raw = collect(TreeSitter.named_children(parent_ts_node))
    isempty(raw) && return CodeRow[]

    parent_n_lines = parent_le - parent_ls + 1

    # Classify each raw named child
    classified = map(raw) do node
        t = TreeSitter.node_type(node)
        is_comment = TreeSitter.is_extra(node)
        mapping = is_comment ? nothing : get(entry.node_types, t, nothing)
        rs = Int(TreeSitter.API.ts_node_start_point(node.ptr).row)   # 0-indexed
        re = Int(TreeSitter.API.ts_node_end_point(node.ptr).row)     # 0-indexed
        (; ts_node=node, is_comment, mapping, row_start=rs, row_end=re)
    end

    # Identify visible mapped nodes (R10/R11)
    visible_indices = Int[]
    for (i, c) in enumerate(classified)
        c.is_comment && continue
        isnothing(c.mapping) && continue
        if c.mapping.class == :landmark
            push!(visible_indices, i)
        elseif c.mapping.class == :detail && parent_n_lines >= detail_threshold
            push!(visible_indices, i)
        end
    end

    # Leaf: no visible children → caller keeps this node as a leaf
    isempty(visible_indices) && return CodeRow[]

    # Apply R14b: absorb immediately preceding adjacent comment blocks.
    # A comment is "adjacent" when its end_row + 1 == next_start_row (0-indexed).
    ls_adj = Dict{Int,Int}()   # visible index → adjusted 1-indexed line_start
    for vi in visible_indices
        first_start = classified[vi].row_start   # 0-indexed
        j = vi - 1
        while j >= 1
            prev = classified[j]
            prev.is_comment         || break  # hit a non-comment
            prev.row_end + 1 != first_start && break  # not adjacent
            first_start = prev.row_start
            j -= 1
        end
        ls_adj[vi] = first_start + 1  # convert to 1-indexed
    end

    # Build _Span list, extracting summary sources (R17/R18).
    spans = _Span[]
    for vi in visible_indices
        c = classified[vi]
        name = something(_query_name(entry, c.ts_node, src), c.mapping.kind)

        # R17: check if the immediately preceding non-comment sibling is a
        # docstring node for this language.
        summary_src::Union{String,Nothing} = nothing
        if !isempty(entry.docstring_types)
            j = vi - 1
            while j >= 1
                prev = classified[j]
                if prev.is_comment
                    j -= 1
                    continue
                end
                if TreeSitter.node_type(prev.ts_node) ∈ entry.docstring_types
                    summary_src = String(TreeSitter.slice(src, prev.ts_node))
                end
                break
            end
        end

        # R18: if no docstring but leading comment lines were absorbed (R14b),
        # use those comment lines as the summary source.
        if isnothing(summary_src) && ls_adj[vi] < c.row_start + 1
            # Lines ls_adj[vi] .. c.row_start (1-indexed) are the absorbed comments.
            summary_src = join(src_lines[ls_adj[vi]:c.row_start], '\n')
        end

        push!(spans, _Span(c.mapping.kind, name, ls_adj[vi], c.row_end + 1, c.ts_node, summary_src))
    end

    # Apply R14a: if adjacent spans share a line, the shared line belongs to the second.
    for i in 2:length(spans)
        if spans[i-1].le >= spans[i].ls
            spans[i-1].le = spans[i].ls - 1
        end
    end

    # Collect non-absorbed comment nodes for R20a standalone comment detection.
    # A comment node is "absorbed" if its row range overlaps any adjusted span's ls.
    absorbed_rows = Set{Int}()
    for sp in spans
        for r in (sp.ls - 1):(sp.ts_node === nothing ? sp.ls - 1 : Int(TreeSitter.API.ts_node_start_point(sp.ts_node.ptr).row))
            push!(absorbed_rows, r)
        end
    end
    comment_nodes = [(; row_start=c.row_start, row_end=c.row_end, ts_node=c.ts_node)
                     for c in classified if c.is_comment && c.row_start ∉ absorbed_rows]

    # Group adjacent comment nodes into contiguous groups (no blank lines between).
    comment_groups = Vector{Tuple{Int,Int,Vector{String}}}()  # (ls, le, src_lines)
    i = 1
    while i <= length(comment_nodes)
        g_ls = comment_nodes[i].row_start + 1  # 1-indexed
        g_le = comment_nodes[i].row_end + 1
        g_src = String[]
        push!(g_src, String(TreeSitter.slice(src, comment_nodes[i].ts_node)))
        j = i + 1
        while j <= length(comment_nodes) &&
              comment_nodes[j].row_start <= comment_nodes[j-1].row_end + 1
            g_le = comment_nodes[j].row_end + 1
            push!(g_src, String(TreeSitter.slice(src, comment_nodes[j].ts_node)))
            j += 1
        end
        push!(comment_groups, (g_ls, g_le, g_src))
        i = j
    end

    # Apply R14c + R15: fill gaps between spans; absorb blank-only gaps (R14c);
    # split non-blank gaps around standalone comment groups (R20a).
    result_spans = _Span[]
    prev_le = parent_ls - 1

    function _fill_gap(gap_ls::Int, gap_le::Int)
        gap_ls > gap_le && return
        if _all_blank(src_lines, gap_ls, gap_le)
            # R14c: absorb blank gap into preceding or extend first node.
            if isempty(result_spans)
                # Will be handled by the caller adjusting the next span's ls.
            else
                result_spans[end].le = gap_le
            end
            return
        end
        # Find comment groups that fall entirely within [gap_ls, gap_le].
        cgs = filter(g -> g[1] >= gap_ls && g[2] <= gap_le, comment_groups)
        if isempty(cgs)
            push!(result_spans, _Span("chunk", "chunk", gap_ls, gap_le, nothing, nothing))
            return
        end
        # Split gap around comment groups.
        cur = gap_ls
        for (cg_ls, cg_le, cg_src) in cgs
            if cur < cg_ls
                sub_ls, sub_le = cur, cg_ls - 1
                if _all_blank(src_lines, sub_ls, sub_le)
                    isempty(result_spans) || (result_spans[end].le = sub_le)
                else
                    push!(result_spans, _Span("chunk", "chunk", sub_ls, sub_le, nothing, nothing))
                end
            end
            cg_summary = join(cg_src, '\n')
            push!(result_spans, _Span("comment", "comment", cg_ls, cg_le, nothing, cg_summary))
            cur = cg_le + 1
        end
        if cur <= gap_le
            sub_ls, sub_le = cur, gap_le
            if _all_blank(src_lines, sub_ls, sub_le)
                isempty(result_spans) || (result_spans[end].le = sub_le)
            else
                push!(result_spans, _Span("chunk", "chunk", sub_ls, sub_le, nothing, nothing))
            end
        end
    end

    for sp in spans
        gap_ls = prev_le + 1
        gap_le = sp.ls - 1
        _fill_gap(gap_ls, gap_le)
        # R14c leading blank: extend first visible span backwards if gap was blank.
        if gap_ls <= gap_le && _all_blank(src_lines, gap_ls, gap_le) && isempty(result_spans)
            sp.ls = gap_ls
        end
        push!(result_spans, sp)
        prev_le = sp.le
    end

    # Handle trailing gap (after last visible node)
    if prev_le < parent_le
        _fill_gap(prev_le + 1, parent_le)
    end

    isempty(result_spans) && return CodeRow[]

    # Assign ordinal-suffix ids (R1) and sibling_order (R16)
    span_names = [sp.name for sp in result_spans]
    span_starts = [sp.ls for sp in result_spans]
    id_suffixes = assign_ordinal_ids(span_names, span_starts)
    qname_suffixes = assign_ordinal_ids(span_names, span_starts)

    # Build rows and recurse
    all_rows = CodeRow[]
    for (i, sp) in enumerate(result_spans)
        node_id = child_node_id(parent_id, id_suffixes[i])
        node_qname = child_qname(parent_qname, qname_suffixes[i])
        span_src = join(src_lines[max(1, sp.ls):min(length(src_lines), sp.le)], '\n')

        # Extract signature for declarative nodes (R1: declaration line only).
        sig::Union{String,Missing} = missing
        if sp.kind != "chunk" && !isnothing(sp.ts_node)
            ts_start_row = Int(TreeSitter.API.ts_node_start_point(sp.ts_node.ptr).row)
            decl_line_idx = ts_start_row + 1  # 1-indexed
            if 1 <= decl_line_idx <= length(src_lines)
                sig = strip(String(src_lines[decl_line_idx]))
            end
        end

        row = CodeRow(
            node_id.val,
            parent_id.val,
            depth,
            i - 1,
            sp.kind,
            sp.name,
            node_qname.val,
            language,
            _extract_summary(sp.summary_src),
            span_src,
            sig,
            file_path.val,
            sp.ls,
            sp.le,
            sp.le - sp.ls + 1,
            0,  # n_children filled in below
        )

        if sp.kind != "chunk" && !isnothing(sp.ts_node)
            body = _find_body(entry, sp.ts_node)
            child_rows = _build_level(
                body, src, src_lines, entry, language, config, detail_threshold,
                node_id, file_path, depth + 1, sp.ls, sp.le, node_qname,
            )
            n_direct = count(r -> r.parent == node_id.val, child_rows)
            row.n_children = n_direct
            if n_direct > 0
                row.source = missing  # R1: source only on leaves
            end
            push!(all_rows, row)
            append!(all_rows, child_rows)
        else
            push!(all_rows, row)
        end
    end

    return all_rows
end

function _markdown_block_name(block::MarkdownBlock, kind::String)::String
    if block.type_name == "Header"
        header = replace(strip(first(split(block.source, '\n'))), r"^#+\s*" => "")
        return replace(header, "`" => "")
    end
    return kind
end

function _blank_line_chunk_spans(
    src_lines::Vector{<:AbstractString},
)::Vector{Tuple{Int,Int}}
    n_lines = length(src_lines)
    n_lines == 0 && return Tuple{Int,Int}[]

    block_starts = Int[]
    i = 1
    while i <= n_lines
        while i <= n_lines && isempty(strip(src_lines[i]))
            i += 1
        end
        i > n_lines && break

        push!(block_starts, i)
        while i <= n_lines && !isempty(strip(src_lines[i]))
            i += 1
        end
    end

    isempty(block_starts) && return Tuple{Int,Int}[]

    spans = Tuple{Int,Int}[]
    for (idx, block_start) in enumerate(block_starts)
        chunk_ls = idx == 1 ? 1 : block_start
        chunk_le = idx < length(block_starts) ? block_starts[idx + 1] - 1 : n_lines
        push!(spans, (chunk_ls, chunk_le))
    end
    return spans
end

mutable struct _FallbackSpan
    kind::String
    name::String
    ls::Int
    le::Int
    starts_with_closer::Bool
    children::Vector{_FallbackSpan}
end

function _indent_width(line::AbstractString)::Int
    col = 0
    for ch in line
        if ch == ' '
            col += 1
        elseif ch == '\t'
            col += 4 - (col % 4)
        else
            break
        end
    end
    return col
end

_is_blank_line(line::AbstractString)::Bool = isempty(strip(line))

function _first_text(line::AbstractString)::String
    return strip(String(line))
end

function _is_closing_line(line::AbstractString)::Bool
    text = _first_text(line)
    return startswith(text, "}") || startswith(text, ")") ||
           startswith(text, "]") || startswith(text, "</")
end

function _next_nonblank(src_lines::Vector{<:AbstractString}, from::Int, to::Int)::Union{Int,Nothing}
    i = from
    while i <= to
        !_is_blank_line(src_lines[i]) && return i
        i += 1
    end
    return nothing
end

function _prev_nonblank(src_lines::Vector{<:AbstractString}, from::Int, to::Int)::Union{Int,Nothing}
    i = from
    while i >= to
        !_is_blank_line(src_lines[i]) && return i
        i -= 1
    end
    return nothing
end

function _nonblank_count(src_lines::Vector{<:AbstractString}, from::Int, to::Int)::Int
    from > to && return 0
    return count(i -> !_is_blank_line(src_lines[i]), from:to)
end

function _starts_indent_candidate(
    src_lines::Vector{<:AbstractString},
    line::Int,
    parent_le::Int,
)::Bool
    _is_blank_line(src_lines[line]) && return false
    nxt = _next_nonblank(src_lines, line + 1, parent_le)
    isnothing(nxt) && return false
    return _indent_width(src_lines[nxt]) > _indent_width(src_lines[line])
end

function _candidate_base_end(
    src_lines::Vector{<:AbstractString},
    line::Int,
    parent_le::Int,
)::Int
    start_indent = _indent_width(src_lines[line])
    j = _next_nonblank(src_lines, line + 1, parent_le)
    while !isnothing(j)
        j_int = j::Int
        if _indent_width(src_lines[j_int]) <= start_indent
            return j_int - 1
        end
        j = _next_nonblank(src_lines, j_int + 1, parent_le)
    end
    return parent_le
end

function _is_connector_start(
    src_lines::Vector{<:AbstractString},
    line::Int,
    parent_le::Int,
)::Bool
    return _is_closing_line(src_lines[line]) &&
           _starts_indent_candidate(src_lines, line, parent_le)
end

function _fallback_candidate_span(
    src_lines::Vector{<:AbstractString},
    line::Int,
    parent_le::Int,
)::Union{Tuple{Int,Int},Nothing}
    _starts_indent_candidate(src_lines, line, parent_le) || return nothing

    base_le = _candidate_base_end(src_lines, line, parent_le)
    final_le = base_le
    next = _next_nonblank(src_lines, base_le + 1, parent_le)

    if !isnothing(next)
        next_line = next::Int
        if _is_closing_line(src_lines[next_line]) &&
           !_is_connector_start(src_lines, next_line, parent_le)
            body_end = _prev_nonblank(src_lines, base_le, line)
            if !isnothing(body_end) && next_line == (body_end::Int) + 1
                final_le = next_line
            else
                return nothing
            end
        end
    end

    _nonblank_count(src_lines, line, final_le) >= 2 || return nothing
    return (line, final_le)
end

function _accepted_fallback_blocks(
    src_lines::Vector{<:AbstractString},
    parent_ls::Int,
    parent_le::Int,
)::Vector{_FallbackSpan}
    candidates = _FallbackSpan[]
    for line in parent_ls:parent_le
        span = _fallback_candidate_span(src_lines, line, parent_le)
        isnothing(span) && continue
        ls, le = span
        push!(candidates, _FallbackSpan(
            "block", "block", ls, le, _is_closing_line(src_lines[ls]), _FallbackSpan[],
        ))
    end
    return candidates
end

function _direct_fallback_blocks(
    src_lines::Vector{<:AbstractString},
    parent_ls::Int,
    parent_le::Int,
    parent_is_block::Bool,
)::Vector{_FallbackSpan}
    candidates = filter(_accepted_fallback_blocks(src_lines, parent_ls, parent_le)) do sp
        !(parent_is_block && sp.ls == parent_ls && sp.le == parent_le)
    end

    direct = _FallbackSpan[]
    for sp in candidates
        contained = any(other -> other !== sp &&
                                other.ls <= sp.ls &&
                                sp.le <= other.le &&
                                (other.ls < sp.ls || sp.le < other.le),
                        candidates)
        contained || push!(direct, sp)
    end
    sort!(direct, by = sp -> (sp.ls, sp.le))
    return direct
end

function _group_connector_blocks(blocks::Vector{_FallbackSpan})::Vector{_FallbackSpan}
    grouped = _FallbackSpan[]
    i = 1
    while i <= length(blocks)
        run_start = i
        run_end = i
        while run_end < length(blocks) &&
              blocks[run_end + 1].starts_with_closer &&
              blocks[run_end].le + 1 == blocks[run_end + 1].ls
            run_end += 1
        end

        if run_end > run_start
            children = blocks[run_start:run_end]
            push!(grouped, _FallbackSpan(
                "block", "block", children[1].ls, children[end].le, false, children,
            ))
        else
            push!(grouped, blocks[i])
        end
        i = run_end + 1
    end
    return grouped
end

function _fallback_chunk_spans_for_gap(
    src_lines::Vector{<:AbstractString},
    gap_ls::Int,
    gap_le::Int,
)::Vector{_FallbackSpan}
    gap_ls > gap_le && return _FallbackSpan[]
    gap = src_lines[gap_ls:gap_le]
    spans = _blank_line_chunk_spans(gap)
    return [
        _FallbackSpan("chunk", "chunk", gap_ls + ls - 1, gap_ls + le - 1, false, _FallbackSpan[])
        for (ls, le) in spans
    ]
end

function _fallback_children(
    src_lines::Vector{<:AbstractString},
    parent_ls::Int,
    parent_le::Int,
    parent_is_block::Bool,
)::Vector{_FallbackSpan}
    blocks = _group_connector_blocks(
        _direct_fallback_blocks(src_lines, parent_ls, parent_le, parent_is_block))
    result = _FallbackSpan[]
    prev_le = parent_ls - 1

    for block in blocks
        gap_ls = prev_le + 1
        gap_le = block.ls - 1
        if gap_ls <= gap_le
            if _all_blank(src_lines, gap_ls, gap_le)
                if isempty(result)
                    block.ls = gap_ls
                else
                    result[end].le = gap_le
                end
            else
                append!(result, _fallback_chunk_spans_for_gap(src_lines, gap_ls, gap_le))
            end
        end
        push!(result, block)
        prev_le = block.le
    end

    if prev_le < parent_le
        gap_ls = prev_le + 1
        gap_le = parent_le
        if _all_blank(src_lines, gap_ls, gap_le)
            isempty(result) || (result[end].le = gap_le)
        else
            append!(result, _fallback_chunk_spans_for_gap(src_lines, gap_ls, gap_le))
        end
    end

    if isempty(result) && !_all_blank(src_lines, parent_ls, parent_le)
        append!(result, _fallback_chunk_spans_for_gap(src_lines, parent_ls, parent_le))
    end

    return filter(sp -> !(parent_is_block && sp.kind == "block" &&
                          sp.ls == parent_ls && sp.le == parent_le), result)
end

function _build_fallback_child_rows(
    src_lines::Vector{<:AbstractString},
    spans::Vector{_FallbackSpan},
    language::Union{String,Missing},
    file_path::FilePath,
    parent_id::NodeId,
    depth::Int,
    parent_qname::QName,
)::Vector{CodeRow}
    isempty(spans) && return CodeRow[]

    span_names = [sp.name for sp in spans]
    span_starts = [sp.ls for sp in spans]
    id_suffixes = assign_ordinal_ids(span_names, span_starts)
    qname_suffixes = assign_ordinal_ids(span_names, span_starts)

    rows = CodeRow[]
    for (i, sp) in enumerate(spans)
        node_id = child_node_id(parent_id, id_suffixes[i])
        node_qname = child_qname(parent_qname, qname_suffixes[i])
        child_spans = sp.kind == "block" && isempty(sp.children) ?
            _fallback_children(src_lines, sp.ls, sp.le, true) :
            sp.children
        child_rows = _build_fallback_child_rows(
            src_lines, child_spans, language, file_path, node_id, depth + 1, node_qname)
        n_direct = count(r -> r.parent == node_id.val, child_rows)
        span_src = join(src_lines[max(1, sp.ls):min(length(src_lines), sp.le)], '\n')
        row = CodeRow(
            node_id.val,
            parent_id.val,
            depth,
            i - 1,
            sp.kind,
            sp.name,
            node_qname.val,
            language,
            missing,
            n_direct == 0 ? span_src : missing,
            missing,
            file_path.val,
            sp.ls,
            sp.le,
            sp.le - sp.ls + 1,
            n_direct,
        )
        push!(rows, row)
        append!(rows, child_rows)
    end
    return rows
end

function _build_fallback_rows(
    src::String,
    src_lines::Vector{<:AbstractString},
    language::Union{String,Missing},
    file_row::CodeRow,
    file_id::NodeId,
    file_path::FilePath,
    depth::Int,
    file_qname::QName,
)::Vector{CodeRow}
    if _all_blank(src_lines, 1, length(src_lines))
        file_row.source = src
        return [file_row]
    end

    spans = _fallback_children(src_lines, 1, length(src_lines), false)
    child_rows = _build_fallback_child_rows(
        src_lines, spans, language, file_path, file_id, depth + 1, file_qname)
    file_row.n_children = count(r -> r.parent == file_id.val, child_rows)
    return vcat([file_row], child_rows)
end

function _build_markdown_rows(
    src::String,
    entry::LanguageEntry,
    detail_threshold::Int,
    file_id::NodeId,
    file_path::FilePath,
    parent_id::NodeId,
    depth::Int,
    parent_qname::QName=QName(""),
)::Vector{CodeRow}
    src_lines = split(src, '\n')
    if !isempty(src_lines) && isempty(src_lines[end])
        pop!(src_lines)
    end
    n_lines = max(length(src_lines), 1)

    file_name = basename(file_path.val)
    file_qname = child_qname(parent_qname, file_name)

    file_row = CodeRow(
        file_id.val,
        parent_id.val,
        depth,
        0,
        "file",
        file_name,
        file_qname.val,
        "markdown",
        missing,
        missing,
        missing,
        file_path.val,
        1,
        n_lines,
        n_lines,
        0,
    )

    blocks = parse_markdown_blocks(src)
    visible_blocks = NamedTuple{(:block, :mapping), Tuple{MarkdownBlock,NodeMapping}}[]
    for block in blocks
        mapping = get(entry.node_types, block.type_name, nothing)
        isnothing(mapping) && continue
        if mapping.class == :landmark || (mapping.class == :detail && n_lines >= detail_threshold)
            push!(visible_blocks, (block = block, mapping = mapping))
        end
    end

    if isempty(visible_blocks)
        file_row.source = src
        return [file_row]
    end

    spans = _Span[]
    prev_le = 0
    for vb in visible_blocks
        gap_ls = prev_le + 1
        gap_le = vb.block.line_start - 1
        block_ls = vb.block.line_start
        if gap_ls <= gap_le && !_all_blank(src_lines, gap_ls, gap_le)
            push!(spans, _Span("chunk", "chunk", gap_ls, gap_le, nothing, nothing))
        elseif gap_ls <= gap_le && !isempty(spans)
            spans[end].le = gap_le
        elseif gap_ls <= gap_le
            block_ls = gap_ls
        end

        push!(spans, _Span(
            vb.mapping.kind,
            _markdown_block_name(vb.block, vb.mapping.kind),
            block_ls,
            vb.block.line_end,
            nothing,
            nothing,
        ))
        prev_le = vb.block.line_end
    end

    if prev_le < n_lines
        gap_ls = prev_le + 1
        gap_le = n_lines
        if !_all_blank(src_lines, gap_ls, gap_le)
            push!(spans, _Span("chunk", "chunk", gap_ls, gap_le, nothing, nothing))
        elseif !isempty(spans)
            spans[end].le = gap_le
        end
    end

    span_names = [sp.name for sp in spans]
    span_starts = [sp.ls for sp in spans]
    id_suffixes = assign_ordinal_ids(span_names, span_starts)
    qname_suffixes = assign_ordinal_ids(span_names, span_starts)

    child_rows = CodeRow[]
    for (i, sp) in enumerate(spans)
        node_qname = child_qname(file_qname, qname_suffixes[i])
        span_src = join(src_lines[max(1, sp.ls):min(length(src_lines), sp.le)], '\n')
        push!(child_rows, CodeRow(
            child_node_id(file_id, id_suffixes[i]).val,
            file_id.val,
            depth + 1,
            i - 1,
            sp.kind,
            sp.name,
            node_qname.val,
            "markdown",
            missing,
            span_src,
            missing,
            file_path.val,
            sp.ls,
            sp.le,
            sp.le - sp.ls + 1,
            0,
        ))
    end

    file_row.n_children = length(child_rows)
    return vcat([file_row], child_rows)
end

# ---------------------------------------------------------------------------
# File-level builder
# ---------------------------------------------------------------------------

"""
    build_file_rows(src, language, config, detail_threshold,
                    file_id, file_path, parent_id, depth) -> Vector{CodeRow}

Build all db.code rows for a single file, including the file node itself
and all its descendant code nodes.
"""
function build_file_rows(
    src::String,
    language::Union{String,Missing},
    config::LanguageConfig,
    detail_threshold::Int,
    file_id::NodeId,
    file_path::FilePath,
    parent_id::NodeId,
    depth::Int,
    parent_qname::QName=QName(""),
)::Vector{CodeRow}

    src_lines = split(src, '\n')
    # Strip the trailing empty element that split produces when source ends with \n.
    if !isempty(src_lines) && isempty(src_lines[end])
        pop!(src_lines)
    end
    n_lines = length(src_lines)
    n_lines == 0 && (n_lines = 1)

    file_name = basename(file_path.val)
    file_qname = child_qname(parent_qname, file_name)

    file_row = CodeRow(
        file_id.val,
        parent_id.val,
        depth,
        0,        # sibling_order (set by caller)
        "file",
        file_name,
        file_qname.val,
        language,
        missing,  # summary
        missing,  # source
        missing,  # signature
        file_path.val,
        1,
        n_lines,
        n_lines,
        0,        # n_children filled in below
    )

    entry = ismissing(language) ? nothing : get(config.languages, language, nothing)
    if !ismissing(language) && language == "markdown" && !isnothing(entry)
        return _build_markdown_rows(
            src, entry, detail_threshold, file_id, file_path, parent_id, depth, parent_qname,
        )
    end

    # R8: unknown language, missing grammar, or parser failure → fallback parser.
    if isnothing(entry) || isnothing(entry.grammar_symbol)
        return _build_fallback_rows(
            src, src_lines, language, file_row, file_id, file_path, depth, file_qname,
        )
    end

    tree = try
        parse_source(src, entry.grammar_symbol)
    catch e
        _is_query_compile_failure(e) && rethrow()
        nothing
    end
    if isnothing(tree)
        return _build_fallback_rows(
            src, src_lines, language, file_row, file_id, file_path, depth, file_qname,
        )
    end

    # GC.@preserve keeps `tree` alive for the entire node traversal.
    # TreeSitter 0.1.0 Node does not hold a reference to its Tree, so without
    # this the GC could free the tree while nodes are still in use.
    child_rows = GC.@preserve tree begin
        root_node = TreeSitter.root(tree)
        _build_level(
            root_node, src, src_lines, entry, language, config, detail_threshold,
            file_id, file_path, depth + 1, 1, n_lines, file_qname,
        )
    end

    file_row.n_children = count(r -> r.parent == file_id.val, child_rows)
    return vcat([file_row], child_rows)
end
