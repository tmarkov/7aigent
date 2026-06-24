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
function extract_symbols!(db::CodeTreeDB)::Nothing
    code_df  = getfield(db.code,    :_df)
    syms_df  = getfield(db.symbols, :_df)
    buffer   = db._buffer
    config   = db.config

    # R21c: known_names = name values from non-Markdown code nodes.
    non_md_names = filter(r -> !ismissing(r.language) && r.language != "markdown", code_df)
    known_names = Set{String}(skipmissing(non_md_names.name))
    new_rows = SymbolRow[]

    # R21b: process non-Markdown files first, then Markdown, so known_names
    # (built from code_df above) is available for Markdown extraction.
    for lang_first in (false, true)   # false = non-md, true = md
        for file_rel in sort(unique(skipmissing(code_df.file)))
            lang_val = language_for_file(config, file_rel)
            ismissing(lang_val) && continue
            is_md = (lang_val == "markdown")
            is_md == lang_first || continue

            lang_entry = get(config.languages, lang_val, nothing)
            isnothing(lang_entry) && continue

            src = get(buffer, file_rel, "")
            file_leaves = filter(
                r -> isequal(r.file, file_rel) && r.n_children == 0,
                code_df,
            )
            isempty(file_leaves) && continue

            append!(new_rows,
                _extract_file_symbols(src, lang_val, lang_entry, file_leaves,
                                      code_df, known_names, config))
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
    return nothing
end

# ---------------------------------------------------------------------------
# Shared per-file extraction core
# ---------------------------------------------------------------------------

"""
    _extract_file_symbols(src, lang_val, lang_entry, file_leaves, code_df,
                          known_names, config)
    -> Vector{NamedTuple{(:node_id, :symbol, :kind)}}

Core per-file symbol extraction used by both `extract_symbols!` (global pass)
and `_extract_symbols_for_file` (single-file update after `update_source!`).

- For non-Markdown: parses `src` with the language grammar, runs call/def/ref
  queries, and classifies captures in each leaf's line range as `call` or
  `var_ref`.
- For Markdown: extracts symbols from fenced/indented blocks and inline spans,
  intersecting untagged content with `known_names` (R21a, R21c).

Returns raw (possibly duplicate) entries; callers deduplicate if needed.
"""
function _extract_file_symbols(
    src::String,
    lang_val::String,
    lang_entry::LanguageEntry,
    file_leaves::AbstractDataFrame,
    code_df::AbstractDataFrame,
    known_names::Set{String},
    config::LanguageConfig,
)::Vector{SymbolRow}
    result = SymbolRow[]

    if lang_val == "markdown"
        for lrow in eachrow(file_leaves)
            nid = lrow.id
            leaf_src = something(lrow.source, "")
            md_syms = _extract_markdown_symbols(leaf_src, known_names, config)
            for (name, kind) in md_syms
                push!(result, (node_id=nid, symbol=name, kind=kind))
            end
        end
        return result
    end

    # Non-Markdown: tree-sitter query extraction
    isnothing(lang_entry.grammar_symbol) && return result
    tree = parse_source(src, lang_entry.grammar_symbol)
    isnothing(tree) && return result

    # GC.@preserve keeps tree alive — TreeSitter 0.1.0 Node doesn't hold a
    # reference to its Tree, so without this the GC could free the tree while
    # root_node (a raw pointer into tree memory) is still in use.
    call_caps, def_caps, ref_caps = GC.@preserve tree begin
        root_node = TreeSitter.root(tree)
        (
            _run_queries(lang_entry.call_patterns,       src, root_node, lang_entry.grammar_symbol),
            _run_queries(lang_entry.definition_patterns, src, root_node, lang_entry.grammar_symbol),
            _run_ident_query(src, root_node, lang_entry.grammar_symbol),
        )
    end

    for lrow in eachrow(file_leaves)
        ismissing(lrow.line_start) && continue
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
        for (names, kind) in ((calls, "call"), (var_refs, "var_ref"))
            for name in names
                push!(result, (node_id=nid, symbol=name, kind=kind))
            end
        end
    end

    return result
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
    grammar::Union{Symbol, Nothing},
)::Vector{Tuple{String,String,Int,Int}}
    results = Tuple{String,String,Int,Int}[]
    isempty(patterns) && return results
    isnothing(grammar) && return results
    lang_obj = Language(grammar)
    for pat in patterns
        q = try
            Query(lang_obj, pat)
        catch e
            _is_query_compile_failure(e) || rethrow()
            continue
        end
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
    grammar::Union{Symbol, Nothing},
)::Vector{Tuple{String,String,Int,Int}}
    pat = "(identifier) @ref"
    return _run_queries([pat], src, root_node, grammar)
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
)::Set{Tuple{String,String}}
    # Returns (name, kind) pairs where kind is "call" or "var_ref" (R21a).
    result = Set{Tuple{String,String}}()

    # Find all fenced code blocks: ```lang\n...\n``` or ```\n...\n```
    fence_re = r"```([\w+#-]*)\n(.*?)```"s
    for m in eachmatch(fence_re, src)
        lang_tag = lowercase(strip(m.captures[1]))
        block    = String(m.captures[2])

        if !isempty(lang_tag)
            # Tagged block: use language grammar (R21a first rule)
            block_lang = haskey(config.languages, lang_tag) ? lang_tag :
                         get(config.extensions, "." * lang_tag, nothing)
            if !isnothing(block_lang)
                block_entry = get(config.languages, block_lang, nothing)
                if !isnothing(block_entry) && !isnothing(block_entry.grammar_symbol)
                    syms = _extract_tagged_block_symbols(block, block_entry)
                    for sym in syms
                        push!(result, sym)
                    end
                    continue
                end
            end
            # Unknown tag → fall through to intersection
        end

        # Untagged (or unknown-tagged) block: intersect with known_names (R21a).
        # R21a: if followed by `(` → "call", otherwise "var_ref".
        _classify_block_tokens!(result, block, known_names)
    end

    # Indented code blocks (R21a: four-space or tab-indented per CommonMark).
    # Collect consecutive lines starting with 4 spaces or a tab as a single block.
    lines = split(src, '\n')
    indent_block = String[]
    for line in lines
        if startswith(line, "    ") || startswith(line, "\t")
            push!(indent_block, line)
        else
            if !isempty(indent_block)
                block_text = join(indent_block, '\n')
                _classify_block_tokens!(result, block_text, known_names)
                empty!(indent_block)
            end
        end
    end
    if !isempty(indent_block)
        block_text = join(indent_block, '\n')
        _classify_block_tokens!(result, block_text, known_names)
    end

    # Inline backtick spans: `name` — intersect with known_names
    # NOTE: This is disabled because inline backticks in paragraph text should not
    # contribute symbols to that paragraph node. Symbols should only come from code blocks.
    # inline_re = r"`([^`\n]+)`"
    # for m in eachmatch(inline_re, src)
    #     content = strip(m.captures[1])
    #     _classify_block_tokens!(result, content, known_names)
    # end

    return result
end

# Classify identifier tokens from a code block/span as "call" or "var_ref" (R21a).
# A token followed by `(` is a call; otherwise var_ref.
function _classify_block_tokens!(
    result::Set{Tuple{String,String}},
    text::AbstractString,
    known_names::Set{String},
)::Nothing
    for m in eachmatch(r"\b([A-Za-z_][A-Za-z0-9_!?.]*)\b(\s*\(?)", text)
        name = m.captures[1]
        name ∈ known_names || continue
        # Check if there's a '(' after the identifier (possibly with whitespace)
        trail = m.captures[2]
        kind = endswith(strip(trail), "(") ? "call" : "var_ref"
        push!(result, (name, kind))
    end
    return nothing
end

# Parse a tagged code block using the language config's call and definition
# patterns, producing ("name", "call"|"var_ref") pairs (R21a).
function _extract_tagged_block_symbols(
    block::String,
    block_entry::LanguageEntry,
)::Set{Tuple{String,String}}
    result = Set{Tuple{String,String}}()
    isnothing(block_entry.grammar_symbol) && return result

    tree = parse_source(block, block_entry.grammar_symbol)
    isnothing(tree) && return result

    call_caps, def_caps, ref_caps = GC.@preserve tree begin
        root_node = TreeSitter.root(tree)
        (
            _run_queries(block_entry.call_patterns, block, root_node, block_entry.grammar_symbol),
            _run_queries(block_entry.definition_patterns, block, root_node, block_entry.grammar_symbol),
            _run_ident_query(block, root_node, block_entry.grammar_symbol),
        )
    end

    last_line = max(count(==('\n'), block), 0)
    calls = Set{String}(_caps_in(call_caps, 0, last_line))
    defs = Set{String}(_caps_in(def_caps, 0, last_line))
    refs = Set{String}(_caps_in(ref_caps, 0, last_line))

    for name in calls
        push!(result, (name, "call"))
    end
    for name in setdiff(refs, defs, calls)
        push!(result, (name, "var_ref"))
    end
    return result
end
