# Symbol extraction (R21, R21a, R21b, R21c, R22).
#
# Two-pass algorithm (R21b):
#   Pass 1 — non-Markdown leaf nodes: extract call and var_ref symbols using
#             tree-sitter queries.  Collect all symbol names into `known_names`.
#   Pass 2 — Markdown leaf nodes: extract symbols from fenced code blocks and
#             inline backtick spans, intersecting untagged content with known_names.

const _IDENT_RE = r"\b([A-Za-z_][A-Za-z0-9_]*)\b"

"""
    extract_symbols!(db::CodeTreeDB)

Populate `db.symbols` with call and var_ref rows for every leaf node.
Modifies the underlying DataFrame in-place; safe to call once after `load`.
"""
function extract_symbols!(db::CodeTreeDB)
    code_df  = getfield(db.code,    :_df)
    syms_df  = getfield(db.symbols, :_df)
    buffer   = db._buffer
    config   = db.config

    known_names = Set{String}()
    new_rows = NamedTuple{(:node_id, :symbol, :kind), Tuple{String,String,String}}[]

    # -------------------------------------------------------------------------
    # Pass 1 — non-Markdown code files (R21b: index before Markdown)
    # -------------------------------------------------------------------------
    for file_rel in sort(unique(skipmissing(code_df.file)))
        # Determine language
        lang_val = language_for_file(config, file_rel)
        ismissing(lang_val) && continue
        lang = lang_val
        lang == "markdown" && continue
        lang ∉ ("cpp", "julia") && continue

        src  = get(buffer, file_rel, "")
        tree = parse_source(src, lang)
        isnothing(tree) && continue

        lang_entry = get(config.languages, lang, nothing)
        isnothing(lang_entry) && continue

        # leaf nodes for this file
        file_leaves = filter(
            r -> isequal(r.file, file_rel) && r.n_children == 0,
            code_df,
        )
        isempty(file_leaves) && continue

        root_node = TreeSitter.root(tree)

        # Pre-run all queries once per file; bucket captures by row range.
        # GC.@preserve keeps tree alive — 0.1.0 Node doesn't hold a tree ref.
        call_caps, def_caps, ref_caps = GC.@preserve tree begin
            (
                _run_queries(lang_entry.call_patterns,       src, root_node, lang),
                _run_queries(lang_entry.definition_patterns, src, root_node, lang),
                _run_ident_query(src, root_node, lang),
            )
        end

        for lrow in eachrow(file_leaves)
            ls0 = lrow.line_start - 1  # 0-indexed
            le0 = lrow.line_end   - 1

            # Use enclosing function scope for loc_defs so that names defined
            # in sibling chunks of the same function are still excluded (R21).
            scope_ls0, scope_le0 = _enclosing_scope_range(lrow, code_df)

            calls    = Set{String}(_caps_in(call_caps, ls0, le0))
            loc_defs = Set{String}(_caps_in(def_caps,  scope_ls0, scope_le0))
            all_refs = Set{String}(_caps_in(ref_caps,  ls0, le0))
            var_refs = setdiff(all_refs, loc_defs, calls)

            nid = lrow.id
            for name in calls
                push!(known_names, name)
                push!(new_rows, (node_id=nid, symbol=name, kind="call"))
            end
            for name in var_refs
                push!(known_names, name)
                push!(new_rows, (node_id=nid, symbol=name, kind="var_ref"))
            end
        end
    end

    # -------------------------------------------------------------------------
    # Pass 2 — Markdown files (R21a, R21c)
    # -------------------------------------------------------------------------
    for file_rel in sort(unique(skipmissing(code_df.file)))
        lang_val = language_for_file(config, file_rel)
        ismissing(lang_val) && continue
        lang_val == "markdown" || continue

        src = get(buffer, file_rel, "")
        md_leaves = filter(
            r -> isequal(r.file, file_rel) && r.n_children == 0,
            code_df,
        )
        isempty(md_leaves) && continue

        # For Markdown there is typically one leaf (the whole file).
        for lrow in eachrow(md_leaves)
            md_syms = _extract_markdown_symbols(src, known_names, config)
            nid = lrow.id
            for name in md_syms
                push!(new_rows, (node_id=nid, symbol=name, kind="call"))
            end
        end
    end

    # Append to db.symbols (dedup within node)
    seen = Set{Tuple{String,String,String}}()
    for r in new_rows
        key = (r.node_id, r.symbol, r.kind)
        key ∈ seen && continue
        push!(seen, key)
        push!(syms_df, r)
    end
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Run a list of tree-sitter query strings against `root_node` and return
# all (capture_name, symbol_text, row_start, row_end) tuples.
function _run_queries(
    patterns::Vector{String},
    src::String,
    root_node::TreeSitter.Node,
    language::String,
)::Vector{Tuple{String,String,Int,Int}}
    results = Tuple{String,String,Int,Int}[]
    isempty(patterns) && return results
    lang_obj = language == "cpp" ?
        Language(:cpp) :
        Language(:julia)
    for pat in patterns
        q = try Query(lang_obj, pat) catch; continue end
        cursor = TreeSitter.QueryCursor()
        TreeSitter.exec(cursor, q, root_node)
        # TreeSitter 0.1.0 does not define iterate(::QueryCursor); use next_match.
        # Captures are Node values directly; capture name needs the raw index.
        while true
            m = TreeSitter.next_match(cursor)
            m === nothing && break
            for i in 1:TreeSitter.capture_count(m)
                raw_cap   = unsafe_load(m.obj.captures, i)
                cap_node  = TreeSitter.Node(raw_cap.node)
                name_len  = Ref{UInt32}(0)
                name_ptr  = TreeSitter.API.ts_query_capture_name_for_id(
                                q.ptr, raw_cap.index, name_len)
                # name_ptr is Cstring (null-terminated); cast for length-bounded copy
                cap_name  = unsafe_string(Ptr{UInt8}(name_ptr), name_len[])
                text      = String(TreeSitter.slice(src, cap_node))
                rs        = Int(TreeSitter.API.ts_node_start_point(cap_node.ptr).row)
                re        = Int(TreeSitter.API.ts_node_end_point(cap_node.ptr).row)
                push!(results, (cap_name, text, rs, re))
            end
        end
    end
    return results
end

# Run an "all identifier references" query.
function _run_ident_query(
    src::String,
    root_node::TreeSitter.Node,
    language::String,
)::Vector{Tuple{String,String,Int,Int}}
    pat = "(identifier) @ref"
    return _run_queries([pat], src, root_node, language)
end

# Filter captures to those whose start row falls in [ls0, le0] (0-indexed).
function _caps_in(
    caps::Vector{Tuple{String,String,Int,Int}},
    ls0::Int,
    le0::Int,
)::Vector{String}
    return [text for (_, text, rs, _) in caps if ls0 <= rs <= le0]
end

# Return the 0-indexed (ls, le) of the enclosing function scope for a leaf row.
# If the leaf itself is a function/method, its own range is the scope.
# Otherwise walk up parents to find the nearest function ancestor.
function _enclosing_scope_range(leaf_row, code_df)::Tuple{Int,Int}
    own_range = (leaf_row.line_start - 1, leaf_row.line_end - 1)
    leaf_row.kind in ("function", "method") && return own_range
    current_id = leaf_row.parent
    while !ismissing(current_id)
        rows = filter(r -> r.id == current_id, code_df)
        isempty(rows) && break
        row = first(eachrow(rows))
        row.kind in ("function", "method") && return (row.line_start - 1, row.line_end - 1)
        current_id = row.parent
    end
    return own_range
end

# ---------------------------------------------------------------------------
# Markdown symbol extraction (R21a, R21c)
# ---------------------------------------------------------------------------

function _extract_markdown_symbols(
    src::String,
    known_names::Set{String},
    config::LanguageConfig,
)::Set{String}
    result = Set{String}()

    # Find all fenced code blocks: ```lang\n...\n``` or ```\n...\n```
    # Capture (optional_lang, block_content)
    fence_re = r"```([\w+#-]*)\n(.*?)```"s
    for m in eachmatch(fence_re, src)
        lang_tag = strip(m.captures[1])
        block    = String(m.captures[2])

        if !isempty(lang_tag)
            # Tagged block: use language grammar (R21a first rule)
            block_lang = get(config.extensions, "." * lang_tag, nothing)
            if !isnothing(block_lang) && block_lang ∈ ("cpp", "julia")
                syms = _parse_block_symbols(block, block_lang)
                union!(result, syms)
                continue
            end
            # Unknown tag → fall through to intersection
        end

        # Untagged (or unknown-tagged) block: intersect with known_names (R21a)
        tokens = Set(m2.captures[1] for m2 in eachmatch(_IDENT_RE, block))
        union!(result, intersect(tokens, known_names))
    end

    # Inline backtick spans: `name` — intersect with known_names
    inline_re = r"`([^`\n]+)`"
    for m in eachmatch(inline_re, src)
        content = strip(m.captures[1])
        # Split by non-identifier chars in case of compound spans
        for tok in eachmatch(_IDENT_RE, content)
            name = tok.captures[1]
            name ∈ known_names && push!(result, name)
        end
    end

    return result
end

# Parse a code block string with the given language grammar and return
# all identifier names found in the AST (tagged block, R21a).
function _parse_block_symbols(block::String, language::String)::Set{String}
    result = Set{String}()
    tree = parse_source(block, language)
    isnothing(tree) && return result
    caps = GC.@preserve tree begin
        root_node = TreeSitter.root(tree)
        _run_ident_query(block, root_node, language)
    end
    for (_, text, _, _) in caps
        push!(result, text)
    end
    return result
end
