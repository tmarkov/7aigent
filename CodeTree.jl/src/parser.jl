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

struct MarkdownBlock
    type_name::String
    source::String
    line_start::Int
    line_end::Int
end

function parse_markdown_blocks(src::String)::Vector{MarkdownBlock}
    md = Markdown.parse(src)
    ast_blocks = getfield(md, :content)
    scanned_blocks = _scan_markdown_blocks(src)

    if length(ast_blocks) != length(scanned_blocks)
        throw(ErrorException(
            "Markdown block scan mismatch: parsed $(length(ast_blocks)) blocks " *
            "but scanned $(length(scanned_blocks)) source ranges.",
        ))
    end

    return [
        MarkdownBlock(
            String(nameof(typeof(ast_blocks[i]))),
            scanned_blocks[i].source,
            scanned_blocks[i].line_start,
            scanned_blocks[i].line_end,
        )
        for i in eachindex(ast_blocks)
    ]
end

function _scan_markdown_blocks(
    src::String,
)::Vector{NamedTuple{(:source, :line_start, :line_end), Tuple{String,Int,Int}}}
    lines = split(src, '\n')
    if !isempty(lines) && isempty(lines[end])
        pop!(lines)
    end

    blocks = NamedTuple{(:source, :line_start, :line_end), Tuple{String,Int,Int}}[]
    i = 1
    while i <= length(lines)
        stripped = strip(lines[i])
        if isempty(stripped)
            i += 1
            continue
        end

        if startswith(stripped, "```")
            line_start = i
            i += 1
            while i <= length(lines) && !startswith(strip(lines[i]), "```")
                i += 1
            end
            line_end = min(i, length(lines))
            push!(blocks, (
                source = join(lines[line_start:line_end], '\n'),
                line_start = line_start,
                line_end = line_end,
            ))
            i = line_end + 1
            continue
        end

        if occursin(r"^#{1,6}\s+", stripped) || occursin(r"^---+$", stripped)
            push!(blocks, (
                source = lines[i],
                line_start = i,
                line_end = i,
            ))
            i += 1
            continue
        end

        line_start = i
        while i <= length(lines)
            stripped = strip(lines[i])
            if isempty(stripped) || startswith(stripped, "```") ||
               occursin(r"^#{1,6}\s+", stripped) || occursin(r"^---+$", stripped)
                break
            end
            i += 1
        end
        line_end = i - 1
        push!(blocks, (
            source = join(lines[line_start:line_end], '\n'),
            line_start = line_start,
            line_end = line_end,
        ))
    end

    return blocks
end
