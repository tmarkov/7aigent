# Default startup: index the workspace and bind the database to Main.db.
# Edit .7aigent/startup.jl in your workspace to customise this behaviour.

# Workaround: IJulia's stdio type is missing ioproperties in Julia 1.12+,
# which causes IOContext construction to fail when printing arrays/vectors.
try
    Base.eval(:(ioproperties(io::$(typeof(stdout))) = ImmutableDict{Symbol,Any}()))
catch e
    @warn "ioproperties patch failed" e
end

using DataFrames, DataFramesMeta

const LLM_DF_TRUNCATE = 360
const LLM_DF_MAX_DISPLAY_COLUMNS = 20
const LLM_DF_MAX_DISPLAY_WIDTH = LLM_DF_TRUNCATE * LLM_DF_MAX_DISPLAY_COLUMNS

function _llm_dataframe_io(io::IO, df::AbstractDataFrame)
    rows, cols = displaysize(io)
    width = max(cols, LLM_DF_TRUNCATE * min(ncol(df), LLM_DF_MAX_DISPLAY_COLUMNS))
    return IOContext(
        io,
        :limit => true,
        :displaysize => (rows, min(width, LLM_DF_MAX_DISPLAY_WIDTH)),
    )
end

function _llm_show_dataframe(
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
    display_io = _llm_dataframe_io(io, df)
    invoke(
        Base.show,
        Tuple{IO, AbstractDataFrame},
        display_io,
        df;
        allrows = allrows,
        allcols = allcols,
        rowlabel = rowlabel,
        summary = summary,
        eltypes = eltypes,
        truncate = truncate,
        kwargs...,
    )
end

Base.show(io::IO, df::DataFrame; kwargs...) =
    _llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::SubDataFrame; kwargs...) =
    _llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::CodeTree.CodeTree; kwargs...) =
    _llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::CodeTree.CodeSymbols; kwargs...) =
    _llm_show_dataframe(io, df; kwargs...)

global db = CodeTree.load("/workspace");
