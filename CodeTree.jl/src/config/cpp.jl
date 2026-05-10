# Built-in configuration for C and C++.

const CPP_ENTRY = LanguageEntry(
    node_types = Dict(
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
    call_patterns = [
        "(call_expression function: (identifier) @call)",
        "(call_expression function: (field_expression field: (field_identifier) @call))",
    ],
    definition_patterns = [
        "(declaration declarator: (identifier) @def)",
        "(init_declarator declarator: (identifier) @def)",
        "(parameter_declaration declarator: (identifier) @def)",
        "(array_declarator declarator: (identifier) @def)",
        "(pointer_declarator declarator: (identifier) @def)",
        "(for_range_loop left: (identifier) @def)",
    ],
    extensions = [".cpp", ".cc", ".cxx", ".hpp", ".h"],
    grammar_symbol = :cpp,
    name_patterns = [
        # function, method, or constructor: identifier directly under function_declarator
        "(function_definition declarator: (function_declarator declarator: (identifier) @name))",
        "(function_definition declarator: (function_declarator declarator: (field_identifier) @name))",
        "(function_definition declarator: (function_declarator declarator: (qualified_identifier) @name))",
        "(function_definition declarator: (function_declarator declarator: (destructor_name) @name))",
        "(function_definition declarator: (function_declarator declarator: (operator_name) @name))",
        # through one wrapper (pointer_declarator, reference_declarator, …)
        "(function_definition declarator: (_ declarator: (function_declarator declarator: (identifier) @name)))",
        "(function_definition declarator: (_ declarator: (function_declarator declarator: (field_identifier) @name)))",
        "(function_definition declarator: (_ declarator: (function_declarator declarator: (qualified_identifier) @name)))",
        "(function_definition declarator: (_ declarator: (function_declarator declarator: (destructor_name) @name)))",
        "(function_definition declarator: (_ declarator: (function_declarator declarator: (operator_name) @name)))",
        # class / struct
        "(class_specifier  name: (type_identifier) @name)",
        "(struct_specifier name: (type_identifier) @name)",
        # namespace
        "(namespace_definition name: (identifier) @name)",
        "(namespace_definition name: (namespace_identifier) @name)",
    ],
    body_fields     = ["body", "consequence"],
    body_node_types = ["compound_statement"],
    docstring_types = String[],
)
