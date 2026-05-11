# Lazily-initialised parser cache — one parser per grammar symbol.
const _PARSERS = Dict{Symbol,TreeSitter.Parser}()

function _get_parser(grammar::Symbol)::TreeSitter.Parser
    return get!(_PARSERS, grammar) do
        Parser(Language(grammar))
    end
end

"""
    parse_source(src, grammar) -> Union{TreeSitter.Tree, Nothing}

Parse `src` with the tree-sitter grammar identified by `grammar` (a `Symbol`
such as `:cpp` or `:julia`). Returns `nothing` when `grammar` is `nothing`.
"""
function parse_source(src::String, grammar::Union{Symbol,Nothing})::Union{TreeSitter.Tree,Nothing}
    isnothing(grammar) && return nothing
    parser = _get_parser(grammar)
    return TreeSitter.parse(parser, src)
end
