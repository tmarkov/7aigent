"""
    MutationError

Raised when a direct mutation of a protected `CodeTree` or `CodeSymbols`
DataFrame is attempted.
"""
struct MutationError <: Exception
    msg::String
end

Base.showerror(io::IO, e::MutationError) = print(io, "MutationError: ", e.msg)

const MUTATION_MSG =
    "direct mutation is not supported; " *
    "use update_source(db, id, new_source) to modify codebase content. " *
    "Only db.code.summary may be written directly."

# ---------------------------------------------------------------------------
# CodeTree — read-only wrapper for db.code
# ---------------------------------------------------------------------------

"""
    CodeTree <: AbstractDataFrame

DataFrame holding the code tree (`db.code`). All DataFrames.jl read, filter,
groupby, and join operations are supported. Direct mutation is forbidden
except for the `summary` column, which may be updated in place as a
session-scoped override.
"""
struct CodeTree <: AbstractDataFrame
    _df::DataFrame
    _summary_baseline::Dict{String,Union{String,Missing}}
    _summary_overrides::Dict{String,Union{String,Missing}}
end

function CodeTree(df::DataFrame)
    return CodeTree(
        df,
        _summary_baseline_from_df(df),
        Dict{String,Union{String,Missing}}(),
    )
end

DataFrames.nrow(ct::CodeTree)::Int     = nrow(getfield(ct, :_df))
DataFrames.ncol(ct::CodeTree)::Int     = ncol(getfield(ct, :_df))
DataFrames.index(ct::CodeTree)         = DataFrames.index(getfield(ct, :_df))
DataFrames._columns(ct::CodeTree)      = DataFrames._columns(getfield(ct, :_df))

# Delegate the getindex signatures DataFrames needs for row/col access. Using
# getfield avoids the AbstractDataFrame getproperty override that would recurse.
function Base.getindex(ct::CodeTree, ::typeof(!), col::Union{Symbol,Integer,AbstractString})
    getindex(getfield(ct, :_df), !, col)
end
function Base.getindex(ct::CodeTree, row::Integer, col::Colon)
    getindex(getfield(ct, :_df), row, col)
end
function Base.getindex(ct::CodeTree, rows, cols)
    getindex(getfield(ct, :_df), rows, cols)
end
function Base.getindex(ct::CodeTree, row::Integer, col)
    getindex(getfield(ct, :_df), row, col)
end

function Base.setindex!(ct::CodeTree, value, inds...)
    _summary_write_target(getfield(ct, :_df), inds...) || throw(MutationError(MUTATION_MSG))
    result = setindex!(getfield(ct, :_df), value, inds...)
    _recompute_summary_overrides!(ct)
    return result
end

# DataFrames internal operations and metadata functions only have concrete
# implementations for DataFrame/SubDataFrame. Delegate them to the inner df so
# that filter, @subset, groupby, sort, and join all work on CodeTree.
# Results are plain DataFrames — read-only protection applies only to direct
# mutation of db.code/db.symbols, not to derived query results.
Base.filter(f, ct::CodeTree)                                   = filter(r -> coalesce(f(r), false), getfield(ct, :_df))
# Resolve ambiguity with DataFrames.filter(::Pair, ::AbstractDataFrame):
DataFrames.filter(pair::Pair, ct::CodeTree; kw...)             = filter(pair, getfield(ct, :_df); kw...)
DataFrames.select(ct::CodeTree, args...; kw...)                = select(getfield(ct, :_df), args...; kw...)
DataFrames.subset(ct::CodeTree, args...; kw...)                = subset(getfield(ct, :_df), args...; kw...)
DataFrames.groupby(ct::CodeTree, args...; kw...)               = groupby(getfield(ct, :_df), args...; kw...)
Base.sort(ct::CodeTree, args...; kw...)                        = sort(getfield(ct, :_df), args...; kw...)
DataFrames._check_consistency(ct::CodeTree)                    = DataFrames._check_consistency(getfield(ct, :_df))
DataFrames.metadatakeys(ct::CodeTree)                          = metadatakeys(getfield(ct, :_df))
DataFrames.metadata(ct::CodeTree, k; kw...)                    = metadata(getfield(ct, :_df), k; kw...)
DataFrames.colmetadatakeys(ct::CodeTree)                       = colmetadatakeys(getfield(ct, :_df))
DataFrames.colmetadatakeys(ct::CodeTree, col)                  = colmetadatakeys(getfield(ct, :_df), col)
DataFrames.colmetadata(ct::CodeTree, col, k; kw...)            = colmetadata(getfield(ct, :_df), col, k; kw...)

# ---------------------------------------------------------------------------
# CodeSymbols — read-only wrapper for db.symbols
# ---------------------------------------------------------------------------

"""
    CodeSymbols <: AbstractDataFrame

Read-only DataFrame holding the symbols table (`db.symbols`). All
DataFrames.jl read operations are supported. Direct mutation raises a
`MutationError`.
"""
struct CodeSymbols <: AbstractDataFrame
    _df::DataFrame
end

DataFrames.nrow(cs::CodeSymbols)::Int   = nrow(getfield(cs, :_df))
DataFrames.ncol(cs::CodeSymbols)::Int   = ncol(getfield(cs, :_df))
DataFrames.index(cs::CodeSymbols)       = DataFrames.index(getfield(cs, :_df))
DataFrames._columns(cs::CodeSymbols)    = DataFrames._columns(getfield(cs, :_df))

function Base.getindex(cs::CodeSymbols, ::typeof(!), col::Union{Symbol,Integer,AbstractString})
    getindex(getfield(cs, :_df), !, col)
end
function Base.getindex(cs::CodeSymbols, row::Integer, col::Colon)
    getindex(getfield(cs, :_df), row, col)
end
function Base.getindex(cs::CodeSymbols, rows, cols)
    getindex(getfield(cs, :_df), rows, cols)
end
function Base.getindex(cs::CodeSymbols, row::Integer, col)
    getindex(getfield(cs, :_df), row, col)
end

Base.setindex!(::CodeSymbols, args...)  = throw(MutationError(MUTATION_MSG))

Base.filter(f, cs::CodeSymbols)                                = filter(r -> coalesce(f(r), false), getfield(cs, :_df))
# Resolve ambiguity with DataFrames.filter(::Pair, ::AbstractDataFrame):
DataFrames.filter(pair::Pair, cs::CodeSymbols; kw...)          = filter(pair, getfield(cs, :_df); kw...)
DataFrames.select(cs::CodeSymbols, args...; kw...)             = select(getfield(cs, :_df), args...; kw...)
DataFrames.subset(cs::CodeSymbols, args...; kw...)             = subset(getfield(cs, :_df), args...; kw...)
DataFrames.groupby(cs::CodeSymbols, args...; kw...)            = groupby(getfield(cs, :_df), args...; kw...)
Base.sort(cs::CodeSymbols, args...; kw...)                     = sort(getfield(cs, :_df), args...; kw...)
DataFrames._check_consistency(cs::CodeSymbols)                 = DataFrames._check_consistency(getfield(cs, :_df))
DataFrames.metadatakeys(cs::CodeSymbols)                       = metadatakeys(getfield(cs, :_df))
DataFrames.metadata(cs::CodeSymbols, k; kw...)                 = metadata(getfield(cs, :_df), k; kw...)
DataFrames.colmetadatakeys(cs::CodeSymbols)                    = colmetadatakeys(getfield(cs, :_df))
DataFrames.colmetadatakeys(cs::CodeSymbols, col)               = colmetadatakeys(getfield(cs, :_df), col)
DataFrames.colmetadata(cs::CodeSymbols, col, k; kw...)         = colmetadata(getfield(cs, :_df), col, k; kw...)

# ---------------------------------------------------------------------------
# CodeTreeDB — container bundling both tables with metadata
# ---------------------------------------------------------------------------

"""
    CodeTreeDB

Container returned by `load`. Holds the code and symbol DataFrames together
with the codebase root path, the language config, and the in-memory file
buffer (R29). `db.code` is queryable like a DataFrame and permits direct
in-memory writes only to the `summary` column.

Fields:
- `code::CodeTree`       — the code tree (`db.code`)
- `symbols::CodeSymbols` — the symbols table (`db.symbols`)
- `root::String`         — absolute path to the codebase root
- `config::LanguageConfig` — language configuration used for indexing
- `detail_threshold::Int` — detail-node line threshold used at load time
- `_buffer::Dict{String,String}` — relative file path → current source content
- `_hashes::Dict{String,String}` — relative file path → SHA-256 hex at last load/write
"""
mutable struct CodeTreeDB
    code::CodeTree
    symbols::CodeSymbols
    root::String
    config::LanguageConfig
    detail_threshold::Int
    _buffer::Dict{String,String}
    _hashes::Dict{String,String}
end

function _summary_baseline_from_df(
    df::DataFrame,
)::Dict{String,Union{String,Missing}}
    baseline = Dict{String,Union{String,Missing}}()
    for row in eachrow(df)
        baseline[string(row.id)] = row.summary
    end
    return baseline
end

function _summary_write_target(df::DataFrame, inds...)::Bool
    isempty(inds) && return false
    try
        return Symbol.(names(df, last(inds))) == [:summary]
    catch
        return false
    end
end

function _recompute_summary_overrides!(ct::CodeTree)::Nothing
    df = getfield(ct, :_df)
    baseline = getfield(ct, :_summary_baseline)
    overrides = getfield(ct, :_summary_overrides)
    empty!(overrides)
    for row in eachrow(df)
        id = string(row.id)
        current_summary = row.summary
        baseline_summary = get(baseline, id, missing)
        isequal(current_summary, baseline_summary) && continue
        overrides[id] = current_summary
    end
    return nothing
end
