# Language config — implemented in Phase 2

"""
    NodeMapping

Classification of a single parser AST node type for a given language.

Fields:
- `class::Symbol` — `:landmark` (always produces a db.code row) or `:detail`
  (only produces a row when the parent spans ≥ `detail_threshold` lines).
- `kind::String` — the db.code `kind` value to assign to matched nodes
  (e.g. `"function"`, `"class"`, `"loop"`, `"conditional"`).
"""
struct NodeMapping
    class::Symbol   # :landmark or :detail
    kind::String
end

"""
    LanguageEntry

Configuration for a single language: AST node type classifications and
tree-sitter query patterns for symbol extraction.

Fields:
- `node_types::Dict{String,NodeMapping}` — maps tree-sitter (or stdlib)
  node type name strings to their `NodeMapping`.
- `call_patterns::Vector{String}` — tree-sitter query strings; each match
  produces a `kind="call"` row in `db.symbols`.
- `definition_patterns::Vector{String}` — tree-sitter query strings; each
  match identifies a locally-bound name, excluded from `var_ref` rows.
"""
struct LanguageEntry
    node_types::Dict{String, NodeMapping}
    call_patterns::Vector{String}
    definition_patterns::Vector{String}
end

"""
    LanguageConfig

Full configuration for a multi-language codebase.

Fields:
- `languages::Dict{String,LanguageEntry}` — keyed by the language name
  string (e.g. `"cpp"`, `"julia"`, `"markdown"`).
- `extensions::Dict{String,String}` — maps file extension strings (including
  the leading dot, e.g. `".cpp"`) to language name strings. Extensions not
  present in this map yield `missing` language (R7, R8).

The package defines this structure but ships no default config; callers
supply a `LanguageConfig` to `load`.
"""
struct LanguageConfig
    languages::Dict{String, LanguageEntry}
    extensions::Dict{String, String}
end

"""
    classify_node(config, language, ast_type) -> Union{NodeMapping, Nothing}

Look up how an AST node type should be classified for `language`.

Returns the `NodeMapping` if the `(language, ast_type)` pair is present in
`config`, or `nothing` if the language is absent or the node type is not
mapped (i.e. it should be ignored / treated as a chunk gap).
"""
function classify_node(config::LanguageConfig, language::String,
                       ast_type::String)::Union{NodeMapping, Nothing}
    entry = get(config.languages, language, nothing)
    isnothing(entry) && return nothing
    return get(entry.node_types, ast_type, nothing)
end

"""
    language_for_file(config, path) -> Union{String, Missing}

Return the language name for a file path based on its extension, or
`missing` if the extension is not in `config.extensions` (R7, R8).
"""
function language_for_file(config::LanguageConfig,
                            path::AbstractString)::Union{String, Missing}
    ext = lowercase(splitext(path)[2])
    return get(config.extensions, ext, missing)
end
