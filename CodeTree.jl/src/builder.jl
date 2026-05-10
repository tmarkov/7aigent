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
        q = try Query(lang_obj, pat) catch; continue end
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
    _build_level(...) -> Vector{Dict{Symbol,Any}}

Build db.code row dicts for all visible descendants of `parent_ts_node`,
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
    parent_id::String,
    file_path::String,
    depth::Int,
    parent_ls::Int,
    parent_le::Int,
)::Vector{Dict{Symbol,Any}}

    raw = collect(TreeSitter.named_children(parent_ts_node))
    isempty(raw) && return Dict{Symbol,Any}[]

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
    isempty(visible_indices) && return Dict{Symbol,Any}[]

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

    isempty(result_spans) && return Dict{Symbol,Any}[]

    # Assign ordinal-suffix ids (R1) and sibling_order (R16)
    id_suffixes = assign_ordinal_ids(
        [sp.name for sp in result_spans],
        [sp.ls   for sp in result_spans],
    )

    # Build rows and recurse
    all_rows = Dict{Symbol,Any}[]
    for (i, sp) in enumerate(result_spans)
        node_id = parent_id * ":" * id_suffixes[i]
        span_src = join(src_lines[max(1, sp.ls):min(length(src_lines), sp.le)], '\n')

        row = Dict{Symbol,Any}(
            :id            => node_id,
            :parent        => parent_id,
            :depth         => depth,
            :sibling_order => i - 1,
            :kind          => sp.kind,
            :name          => sp.name,
            :qname         => missing,
            :language      => language,
            :summary       => _extract_summary(sp.summary_src),
            :source        => span_src,
            :signature     => missing,
            :file          => file_path,
            :line_start    => sp.ls,
            :line_end      => sp.le,
            :n_lines       => sp.le - sp.ls + 1,
            :n_children    => 0,
        )

        if sp.kind != "chunk" && !isnothing(sp.ts_node)
            body = _find_body(entry, sp.ts_node)
            child_rows = _build_level(
                body, src, src_lines, entry, language, config, detail_threshold,
                node_id, file_path, depth + 1, sp.ls, sp.le,
            )
            row[:n_children] = count(r -> r[:parent] == node_id, child_rows)
            push!(all_rows, row)
            append!(all_rows, child_rows)
        else
            push!(all_rows, row)
        end
    end

    return all_rows
end

# ---------------------------------------------------------------------------
# File-level builder
# ---------------------------------------------------------------------------

"""
    build_file_rows(src, language, config, detail_threshold,
                    file_id, file_path, parent_id, depth) -> Vector{Dict{Symbol,Any}}

Build all db.code row dicts for a single file, including the file node itself
and all its descendant code nodes.
"""
function build_file_rows(
    src::String,
    language::Union{String,Missing},
    config::LanguageConfig,
    detail_threshold::Int,
    file_id::String,
    file_path::String,
    parent_id::String,
    depth::Int,
)::Vector{Dict{Symbol,Any}}

    src_lines = split(src, '\n')
    # Strip the trailing empty element that split produces when source ends with \n.
    if !isempty(src_lines) && isempty(src_lines[end])
        pop!(src_lines)
    end
    n_lines = length(src_lines)
    n_lines == 0 && (n_lines = 1)

    file_row = Dict{Symbol,Any}(
        :id            => file_id,
        :parent        => parent_id,
        :depth         => depth,
        :sibling_order => 0,
        :kind          => "file",
        :name          => basename(file_path),
        :qname         => missing,
        :language      => language,
        :summary       => missing,
        :source        => missing,
        :signature     => missing,
        :file          => file_path,
        :line_start    => 1,
        :line_end      => n_lines,
        :n_lines       => n_lines,
        :n_children    => 0,
    )

    # R8: unknown language or no tree-sitter grammar → single leaf
    entry = ismissing(language) ? nothing : get(config.languages, language, nothing)
    if isnothing(entry) || isnothing(entry.grammar_symbol)
        file_row[:source] = src
        return [file_row]
    end

    tree = parse_source(src, entry.grammar_symbol)
    if isnothing(tree)
        file_row[:source] = src
        return [file_row]
    end

    # GC.@preserve keeps `tree` alive for the entire node traversal.
    # TreeSitter 0.1.0 Node does not hold a reference to its Tree, so without
    # this the GC could free the tree while nodes are still in use.
    child_rows = GC.@preserve tree begin
        root_node = TreeSitter.root(tree)
        _build_level(
            root_node, src, src_lines, entry, language, config, detail_threshold,
            file_id, file_path, depth + 1, 1, n_lines,
        )
    end

    file_row[:n_children] = count(r -> r[:parent] == file_id, child_rows)
    return vcat([file_row], child_rows)
end
