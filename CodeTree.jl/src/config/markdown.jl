# Built-in configuration for Markdown.
# Uses Julia stdlib AST type names (R13).

const MARKDOWN_ENTRY = LanguageEntry(
    node_types = Dict(
        "Header"    => NodeMapping(:landmark, "function"),
        "Paragraph" => NodeMapping(:detail, "chunk"),
        "Code"      => NodeMapping(:detail, "chunk"),
    ),
    call_patterns       = String[],
    definition_patterns = String[],
    extensions          = [".md"],
    grammar_symbol      = nothing,
    name_patterns       = String[],
    body_fields         = String[],
    body_node_types     = String[],
    docstring_types     = String[],
)
