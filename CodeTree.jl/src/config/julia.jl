# Built-in configuration for Julia.

const JULIA_ENTRY = LanguageEntry(
    Dict(
        "function_definition"       => NodeMapping(:landmark, "function"),
        "short_function_definition" => NodeMapping(:landmark, "function"),
        "macro_definition"          => NodeMapping(:landmark, "function"),
        "struct_definition"         => NodeMapping(:landmark, "class"),
        "abstract_definition"       => NodeMapping(:landmark, "type"),
        "module_definition"         => NodeMapping(:landmark, "module"),
        "if_statement"              => NodeMapping(:detail, "conditional"),
        "elseif_clause"             => NodeMapping(:detail, "conditional"),
        "for_statement"             => NodeMapping(:detail, "loop"),
        "while_statement"           => NodeMapping(:detail, "loop"),
        "try_statement"             => NodeMapping(:detail, "try"),
        "do_clause"                 => NodeMapping(:detail, "with"),
    ),
    # call_patterns
    ["(call_expression (identifier) @call)",
     "(call_expression (field_expression field: (identifier) @call))"],
    # definition_patterns
    ["(assignment left: (identifier) @def)",
     "(local_declaration (identifier) @def)",
     "(for_binding left: (identifier) @def)",
     "(parameter_list (identifier) @def)",
     "(typed_parameter . (identifier) @def)"],
    # extensions
    [".jl"],
)
