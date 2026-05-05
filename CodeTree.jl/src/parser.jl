# Lazily-initialised parser cache — one parser per language.
const _PARSERS = Dict{String,Any}()

function _get_parser(language::String)
    return get!(_PARSERS, language) do
        if language == "cpp"
            Parser(Language(tree_sitter_cpp_jll))
        elseif language == "julia"
            Parser(Language(tree_sitter_julia_jll))
        else
            error("No tree-sitter parser for language: $language")
        end
    end
end

"""
    parse_source(src, language) -> Union{TreeSitter.Tree, Nothing}

Parse `src` with the tree-sitter grammar for `language`.  Returns `nothing`
when no grammar is available for the given language (e.g. "markdown").
"""
function parse_source(src::String, language::String)::Union{Any,Nothing}
    language ∉ ("cpp", "julia") && return nothing
    parser = _get_parser(language)
    return TreeSitter.parse(parser, src)
end
