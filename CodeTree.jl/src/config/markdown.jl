# Built-in configuration for Markdown.
# Uses Julia stdlib AST type names (R13).

const MARKDOWN_ENTRY = LanguageEntry(
    Dict(
        "Header"    => NodeMapping(:landmark, "function"),
        "Paragraph" => NodeMapping(:detail, "chunk"),
        "Code"      => NodeMapping(:detail, "chunk"),
    ),
    # call_patterns — none for Markdown
    String[],
    # definition_patterns — none for Markdown
    String[],
    # extensions
    [".md"],
)
