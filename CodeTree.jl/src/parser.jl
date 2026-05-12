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

function _is_markdown_fence(line::AbstractString)::Bool
    return startswith(strip(line), "```")
end

function _is_markdown_heading(line::AbstractString)::Bool
    stripped = strip(line)
    return occursin(r"^#{1,6}\s+", stripped) || occursin(r"^---+$", stripped)
end

function _is_markdown_list_item(line::AbstractString)::Bool
    return occursin(r"^\s*(?:[-+*]|\d+[.)])\s+", line)
end

function _is_markdown_list_continuation(line::AbstractString)::Bool
    return occursin(r"^\s{2,}\S", line)
end

function _is_markdown_table_start(lines::Vector{SubString{String}}, i::Int)::Bool
    i >= length(lines) && return false
    header = strip(lines[i])
    delim = strip(lines[i + 1])
    startswith(header, "|") || return false
    return occursin(r"^\|?(?:\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?$", delim)
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

        if _is_markdown_fence(lines[i])
            line_start = i
            i += 1
            while i <= length(lines) && !_is_markdown_fence(lines[i])
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

        if _is_markdown_heading(lines[i])
            push!(blocks, (
                source = lines[i],
                line_start = i,
                line_end = i,
            ))
            i += 1
            continue
        end

        if _is_markdown_list_item(lines[i])
            line_start = i
            i += 1
            while i <= length(lines)
                if _is_markdown_list_item(lines[i]) || _is_markdown_list_continuation(lines[i])
                    i += 1
                    continue
                end

                if isempty(strip(lines[i]))
                    if i < length(lines) && (
                        _is_markdown_list_item(lines[i + 1]) ||
                        _is_markdown_list_continuation(lines[i + 1])
                    )
                        i += 1
                        continue
                    end
                    break
                end

                break
            end
            line_end = i - 1
            push!(blocks, (
                source = join(lines[line_start:line_end], '\n'),
                line_start = line_start,
                line_end = line_end,
            ))
            continue
        end

        if _is_markdown_table_start(lines, i)
            line_start = i
            i += 2
            while i <= length(lines) && startswith(strip(lines[i]), "|")
                i += 1
            end
            line_end = i - 1
            push!(blocks, (
                source = join(lines[line_start:line_end], '\n'),
                line_start = line_start,
                line_end = line_end,
            ))
            continue
        end

        line_start = i
        while i <= length(lines)
            stripped = strip(lines[i])
            if isempty(stripped) ||
               _is_markdown_fence(lines[i]) ||
               _is_markdown_heading(lines[i]) ||
               _is_markdown_list_item(lines[i]) ||
               _is_markdown_table_start(lines, i)
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
