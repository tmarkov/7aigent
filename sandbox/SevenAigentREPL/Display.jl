# Display.jl — DataFrame rendering for LLM consumption

function _llm_visible_row_count(
    io::IO,
    df::AbstractDataFrame,
    allrows::Bool,
)::Int
    allrows && return nrow(df)
    rows, _ = displaysize(io)
    return min(nrow(df), max(rows - 4, 1))
end

function _llm_visible_columns(
    df::AbstractDataFrame,
    allcols::Bool,
)::Vector{String}
    columns = names(df)
    allcols && return columns
    return columns[1:min(length(columns), LLM_DF_MAX_DISPLAY_COLUMNS)]
end

function _llm_markdown_escape(text::AbstractString, truncate::Int)::String
    normalized = replace(String(text), '\r' => " ", '\n' => "\\n", "|" => "\\|")
    return _truncate_display_text(normalized, truncate)
end

function _truncate_display_text(text::String, max_chars::Int)::String
    max_chars <= 0 && return ""
    length(text) <= max_chars && return text
    max_chars <= 3 && return first(text, max_chars)
    return first(text, max_chars - 3) * "..."
end

function _llm_markdown_cell(value, truncate::Int)::String
    text = ismissing(value) ? "missing" : string(value)
    return _llm_markdown_escape(text, truncate)
end

function _llm_header_cell(
    df::AbstractDataFrame,
    column::String,
    eltypes::Bool,
    truncate::Int,
)::String
    label = eltypes ? "$(column) :: $(eltype(df[!, column]))" : column
    return _llm_markdown_escape(label, truncate)
end

"""
    llm_show_dataframe(io, df; kwargs...) -> Nothing

Render `df` as a Markdown table suited for LLM consumption.
"""
function llm_show_dataframe(
    io::IO,
    df::AbstractDataFrame;
    allrows::Bool = false,
    allcols::Bool = false,
    rowlabel::Symbol = :Row,
    summary::Bool = true,
    eltypes::Bool = true,
    truncate::Int = LLM_DF_TRUNCATE,
    kwargs...,
)
    visible_columns = _llm_visible_columns(df, allcols)
    visible_row_count = _llm_visible_row_count(io, df, allrows)

    lines = String[]
    if summary
        push!(lines, "$(nrow(df)) rows x $(ncol(df)) columns DataFrame")
    end

    header_cells = vcat(
        [_llm_markdown_escape(String(rowlabel), truncate)],
        [_llm_header_cell(df, column, eltypes, truncate) for column in visible_columns],
    )
    push!(lines, "| " * join(header_cells, " | ") * " |")
    push!(lines, "| " * join(fill("---", length(header_cells)), " | ") * " |")

    for row_idx in 1:visible_row_count
        row_cells = vcat(
            [_llm_markdown_escape(string(row_idx), truncate)],
            [_llm_markdown_cell(df[row_idx, column], truncate) for column in visible_columns],
        )
        push!(lines, "| " * join(row_cells, " | ") * " |")
    end

    omitted_rows = nrow(df) - visible_row_count
    omitted_columns = ncol(df) - length(visible_columns)
    omitted_rows > 0 && push!(lines, "... $(omitted_rows) more rows omitted")
    omitted_columns > 0 && push!(lines, "... $(omitted_columns) more columns omitted")

    print(io, join(lines, "\n"))
    return nothing
end

"""
    llm_show_dataframe(df; kwargs...) -> Nothing

Render `df` as a Markdown table to stdout.
"""
function llm_show_dataframe(
    df::AbstractDataFrame;
    kwargs...,
)::Nothing
    llm_show_dataframe(stdout, df; kwargs...)
    return nothing
end
