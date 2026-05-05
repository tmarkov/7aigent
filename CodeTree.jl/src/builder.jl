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
# Name extraction — language-specific traversal rules
# ---------------------------------------------------------------------------

function extract_name(node::TreeSitter.Node, src::String, language::String)::Union{String,Nothing}
    t = TreeSitter.node_type(node)
    language == "cpp"   && return _cpp_name(node, src, t)
    language == "julia" && return _julia_name(node, src, t)
    return nothing
end

function _cpp_name(node::TreeSitter.Node, src::String, t::String)::Union{String,Nothing}
    if t == "function_definition"
        try
            decl = TreeSitter.child(node, "declarator")
            return _cpp_decl_name(decl, src)
        catch
            return nothing
        end
    elseif t ∈ ("struct_specifier", "class_specifier")
        for gc in TreeSitter.named_children(node)
            TreeSitter.node_type(gc) == "type_identifier" &&
                return String(TreeSitter.slice(src, gc))
        end
    elseif t == "namespace_definition"
        for gc in TreeSitter.named_children(node)
            TreeSitter.node_type(gc) ∈ ("identifier", "namespace_identifier") &&
                return String(TreeSitter.slice(src, gc))
        end
    end
    return nothing
end

# Recurse through pointer/reference declarator wrappers to find the identifier.
function _cpp_decl_name(node::TreeSitter.Node, src::String)::Union{String,Nothing}
    t = TreeSitter.node_type(node)
    t ∈ ("identifier", "qualified_identifier") && return String(TreeSitter.slice(src, node))
    for gc in TreeSitter.named_children(node)
        r = _cpp_decl_name(gc, src)
        isnothing(r) || return r
    end
    return nothing
end

function _julia_name(node::TreeSitter.Node, src::String, t::String)::Union{String,Nothing}
    if t == "function_definition"
        ncs = collect(TreeSitter.named_children(node))
        isempty(ncs) && return nothing
        sig = ncs[1]
        TreeSitter.node_type(sig) != "signature" && return nothing
        sig_ncs = collect(TreeSitter.named_children(sig))
        isempty(sig_ncs) && return nothing
        return _julia_call_name(sig_ncs[1], src)
    elseif t == "short_function_definition"
        ncs = collect(TreeSitter.named_children(node))
        isempty(ncs) && return nothing
        return _julia_call_name(ncs[1], src)
    elseif t ∈ ("struct_definition", "abstract_definition")
        for gc in TreeSitter.named_children(node)
            tt = TreeSitter.node_type(gc)
            if tt == "type_head"
                for ggc in TreeSitter.named_children(gc)
                    TreeSitter.node_type(ggc) == "identifier" &&
                        return String(TreeSitter.slice(src, ggc))
                end
            end
            tt == "identifier" && return String(TreeSitter.slice(src, gc))
        end
    elseif t == "module_definition"
        for gc in TreeSitter.named_children(node)
            TreeSitter.node_type(gc) == "identifier" &&
                return String(TreeSitter.slice(src, gc))
        end
    elseif t == "macro_definition"
        ncs = collect(TreeSitter.named_children(node))
        isempty(ncs) && return nothing
        return _julia_call_name(ncs[1], src)
    end
    return nothing
end

function _julia_call_name(node::TreeSitter.Node, src::String)::Union{String,Nothing}
    t = TreeSitter.node_type(node)
    t == "identifier" && return String(TreeSitter.slice(src, node))
    if t == "call_expression"
        ncs = collect(TreeSitter.named_children(node))
        isempty(ncs) && return nothing
        return _julia_call_name(ncs[1], src)
    end
    if t == "field_expression"
        # e.g. Base.show → return "show"
        for gc in TreeSitter.named_children(node)
            TreeSitter.node_type(gc) ∈ ("field_identifier", "identifier") &&
                return String(TreeSitter.slice(src, gc))
        end
        return nothing
    end
    if t == "typed_expression"
        # e.g. sort_array(...)::RetType — delegate to the inner call
        ncs = collect(TreeSitter.named_children(node))
        isempty(ncs) && return nothing
        return _julia_call_name(ncs[1], src)
    end
    return nothing
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
# Body extraction — find the compound statement / block to recurse into.
#
# For C++ compound nodes the body is accessed via a named field;
# for Julia it is a `block` node (last named child of the kind listed).
# Returning the original node is a safe fallback (recurse into everything).
# ---------------------------------------------------------------------------

function _body_node(node::TreeSitter.Node, language::String)::TreeSitter.Node
    if language == "cpp"
        for field in ("body", "consequence")
            try
                return TreeSitter.child(node, field)
            catch
            end
        end
        # Fallback: find the first compound_statement among named children.
        for gc in TreeSitter.named_children(node)
            TreeSitter.node_type(gc) == "compound_statement" && return gc
        end
    elseif language == "julia"
        # The body is always a `block` node, typically the last named child.
        for gc in TreeSitter.named_children(node)
            TreeSitter.node_type(gc) == "block" && return gc
        end
    end
    return node
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
        mapping = is_comment ? nothing : classify_node(config, language, t)
        rs = Int(TreeSitter.start_point(node).row)   # 0-indexed
        re = Int(TreeSitter.end_point(node).row)     # 0-indexed
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
        name = something(extract_name(c.ts_node, src, language), c.mapping.kind)

        # R17: check if the immediately preceding non-comment sibling is a
        # string_literal (Julia docstring).
        summary_src::Union{String,Nothing} = nothing
        if language == "julia"
            j = vi - 1
            while j >= 1
                prev = classified[j]
                if prev.is_comment
                    j -= 1
                    continue
                end
                if TreeSitter.node_type(prev.ts_node) == "string_literal"
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
        for r in (sp.ls - 1):(sp.ts_node === nothing ? sp.ls - 1 : Int(TreeSitter.start_point(sp.ts_node).row))
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
            :summary       => _extract_summary(sp.summary_src, language),
            :source        => span_src,
            :signature     => missing,
            :file          => file_path,
            :line_start    => sp.ls,
            :line_end      => sp.le,
            :n_lines       => sp.le - sp.ls + 1,
            :n_children    => 0,
        )

        if sp.kind != "chunk" && !isnothing(sp.ts_node)
            body = _body_node(sp.ts_node, language)
            child_rows = _build_level(
                body, src, src_lines, language, config, detail_threshold,
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

    # R8: unknown language → single leaf
    if ismissing(language) || language ∉ ("cpp", "julia")
        file_row[:source] = src
        return [file_row]
    end

    tree = parse_source(src, language)
    if isnothing(tree)
        file_row[:source] = src
        return [file_row]
    end

    root_node = TreeSitter.root(tree)
    child_rows = _build_level(
        root_node, src, src_lines, language, config, detail_threshold,
        file_id, file_path, depth + 1, 1, n_lines,
    )

    file_row[:n_children] = count(r -> r[:parent] == file_id, child_rows)
    return vcat([file_row], child_rows)
end
