# Built-in configuration for Julia.

const JULIA_ENTRY = LanguageEntry(
    node_types = Dict(
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
    call_patterns = [
        "(call_expression (identifier) @call)",
        "(call_expression (field_expression field: (identifier) @call))",
    ],
    definition_patterns = [
        "(assignment left: (identifier) @def)",
        "(local_declaration (identifier) @def)",
        "(for_binding left: (identifier) @def)",
        "(parameter_list (identifier) @def)",
        "(typed_parameter . (identifier) @def)",
    ],
    extensions = [".jl"],
    grammar_symbol = :julia,
    name_patterns = [
        # function foo(...) — call_expression as direct named child of function_definition
        "(function_definition (call_expression (identifier) @name))",
        "(function_definition (call_expression (field_expression field: (field_identifier) @name)))",
        "(function_definition (call_expression (field_expression field: (identifier) @name)))",
        # function foo(x)::T — typed_expression wraps the call
        "(function_definition (typed_expression (call_expression (identifier) @name)))",
        "(function_definition (typed_expression (call_expression (field_expression field: (field_identifier) @name))))",
        "(function_definition (typed_expression (call_expression (field_expression field: (identifier) @name))))",
        # grammar variants with a `signature` wrapper node
        "(function_definition (signature (call_expression (identifier) @name)))",
        "(function_definition (signature (call_expression (field_expression field: (field_identifier) @name))))",
        "(function_definition (signature (call_expression (field_expression field: (identifier) @name))))",
        "(function_definition (signature (typed_expression (call_expression (identifier) @name))))",
        # direct identifier child (e.g. `function foo end`)
        "(function_definition (identifier) @name)",
        # short_function_definition: f(x) = body
        "(short_function_definition (call_expression (identifier) @name))",
        "(short_function_definition (typed_expression (call_expression (identifier) @name)))",
        "(short_function_definition (call_expression (field_expression field: (field_identifier) @name)))",
        "(short_function_definition (call_expression (field_expression field: (identifier) @name)))",
        "(short_function_definition (identifier) @name)",
        # module_definition
        "(module_definition (identifier) @name)",
        # struct_definition / abstract_definition (with or without type_head wrapper)
        "(struct_definition (type_head (identifier) @name))",
        "(struct_definition (identifier) @name)",
        "(abstract_definition (type_head (identifier) @name))",
        "(abstract_definition (identifier) @name)",
        # macro_definition
        "(macro_definition (call_expression (identifier) @name))",
        "(macro_definition (identifier) @name)",
    ],
    body_fields     = String[],
    body_node_types = ["block"],
    docstring_types = ["string_literal", "triple_string"],
)
