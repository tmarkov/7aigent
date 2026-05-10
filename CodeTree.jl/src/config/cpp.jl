# Built-in configuration for C and C++.

const CPP_ENTRY = LanguageEntry(
    Dict(
        "function_definition"  => NodeMapping(:landmark, "function"),
        "class_specifier"      => NodeMapping(:landmark, "class"),
        "struct_specifier"     => NodeMapping(:landmark, "class"),
        "namespace_definition" => NodeMapping(:landmark, "module"),
        "if_statement"         => NodeMapping(:detail, "conditional"),
        "while_statement"      => NodeMapping(:detail, "loop"),
        "for_statement"        => NodeMapping(:detail, "loop"),
        "do_statement"         => NodeMapping(:detail, "loop"),
        "try_statement"        => NodeMapping(:detail, "try"),
        "switch_statement"     => NodeMapping(:detail, "conditional"),
    ),
    # call_patterns
    ["(call_expression function: (identifier) @call)",
     "(call_expression function: (field_expression field: (field_identifier) @call))"],
    # definition_patterns
    ["(declaration declarator: (identifier) @def)",
     "(init_declarator declarator: (identifier) @def)",
     "(parameter_declaration declarator: (identifier) @def)",
     "(array_declarator declarator: (identifier) @def)",
     "(pointer_declarator declarator: (identifier) @def)",
     "(for_range_loop left: (identifier) @def)"],
    # extensions
    [".cpp", ".cc", ".cxx", ".hpp", ".h"],
)
