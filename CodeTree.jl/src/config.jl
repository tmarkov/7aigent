# Language config: structs, helpers, and per-language overrides.

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
tree-sitter query patterns for symbol extraction and tree building.

Fields:
- `node_types::Dict{String,NodeMapping}` — maps tree-sitter (or stdlib)
  node type name strings to their `NodeMapping`.
- `call_patterns::Vector{String}` — tree-sitter query strings; each match
  produces a `kind="call"` row in `db.symbols`.
- `definition_patterns::Vector{String}` — tree-sitter query strings; each
  match identifies a locally-bound name, excluded from `var_ref` rows.
- `extensions::Vector{String}` — file extensions (with leading dot) that map
  to this language, e.g. `[".cpp", ".cc", ".hpp"]`. Used when constructing a
  `LanguageConfig` from a dict of entries (extensions map derived automatically).
  Pass an empty vector when the extensions are managed by the caller instead.
- `grammar_symbol::Union{Symbol,Nothing}` — tree-sitter grammar symbol (e.g.
  `:cpp`, `:julia`), or `nothing` for languages without a tree-sitter grammar.
- `name_patterns::Vector{String}` — tree-sitter query strings, each capturing
  `@name`. The earliest capture (by row, then column) is used as the node name.
- `body_fields::Vector{String}` — ordered list of named field names to try when
  finding the body node to recurse into (e.g. `["body", "consequence"]`).
- `body_node_types::Vector{String}` — fallback: node types to look for among
  named children when no `body_fields` match (e.g. `["compound_statement"]`).
- `docstring_types::Vector{String}` — AST node types that represent docstrings
  immediately preceding a definition (e.g. `["string_literal", "triple_string"]`
  for Julia). Empty for languages without docstring conventions.
"""
Base.@kwdef struct LanguageEntry
    node_types::Dict{String, NodeMapping}
    call_patterns::Vector{String}       = String[]
    definition_patterns::Vector{String} = String[]
    extensions::Vector{String}          = String[]
    grammar_symbol::Union{Symbol, Nothing} = nothing
    name_patterns::Vector{String}       = String[]
    body_fields::Vector{String}         = String[]
    body_node_types::Vector{String}     = String[]
    docstring_types::Vector{String}     = String[]
end

"""
    LanguageEntry(node_types, call_patterns, definition_patterns) -> LanguageEntry

Convenience constructor with no extensions and no tree-sitter fields.
"""
function LanguageEntry(
    node_types::Dict{String, NodeMapping},
    call_patterns::Vector{String},
    definition_patterns::Vector{String},
)::LanguageEntry
    return LanguageEntry(
        node_types          = node_types,
        call_patterns       = call_patterns,
        definition_patterns = definition_patterns,
    )
end

"""
    LanguageConfig

Full configuration for a multi-language codebase.

Fields:
- `languages::Dict{String,LanguageEntry}` — keyed by the language name
  string (e.g. `"cpp"`, `"julia"`, `"markdown"`).
- `extensions::Dict{String,String}` — maps file extension strings (including
  the leading dot, e.g. `".cpp"`) to language name strings. Derived from
  the `extensions` fields of the individual `LanguageEntry` values.
  Extensions not present in this map yield `missing` language (R7, R8).
"""
struct LanguageConfig
    languages::Dict{String, LanguageEntry}
    extensions::Dict{String, String}
end

"""
    LanguageConfig(languages) -> LanguageConfig

Construct a `LanguageConfig` from a dict of language entries, deriving
the `extensions` map automatically from each entry's `extensions` field.
"""
function LanguageConfig(languages::Dict{String, LanguageEntry})::LanguageConfig
    extensions = Dict{String, String}()
    for (lang, entry) in languages
        for ext in entry.extensions
            extensions[ext] = lang
        end
    end
    return LanguageConfig(languages, extensions)
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

"""
    merge_config(base, overrides) -> LanguageConfig

Return a new `LanguageConfig` that is `base` with the per-language entries
in `overrides` merged in (replacing the corresponding entries in `base`).
The `extensions` map is rebuilt from the merged language set.

Use this to customise a specific language without discarding the defaults:

```julia
my_cpp = LanguageEntry(...)
config  = merge_config(DEFAULT_CONFIG, Dict("cpp" => my_cpp))
db      = load("/workspace", config)
```
"""
function merge_config(
    base::LanguageConfig,
    overrides::Dict{String, LanguageEntry},
)::LanguageConfig
    return LanguageConfig(merge(base.languages, overrides))
end
