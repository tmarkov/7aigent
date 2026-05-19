module SevenAigentREPL

import CodeTree
using Base64
using DataFrames
using IJulia
using TOML
using UUIDs
using CodeTree: CodeTreeDB

export llm_show_dataframe, summarize!
export TodoStatus, pending, in_progress, done
export todo_add!, todo_start!, todo_done!, status

const SUMMARY_COMM_TARGET = "7aigent.summary"
const SUMMARY_INPUT_PROMPT_PREFIX = "7aigent.summary.reply:"
const SUMMARY_RPC_TIMEOUT_SECS = 15.0

const LLM_DF_TRUNCATE = 360
const LLM_DF_MAX_DISPLAY_COLUMNS = 20

const KIND_PRIORITY = Dict(
    "module" => 1,
    "file" => 2,
    "class" => 3,
    "function" => 4,
    "type" => 5,
    "variable" => 6,
    "import" => 7,
    "loop" => 8,
    "conditional" => 9,
    "try" => 10,
    "with" => 11,
    "comment" => 12,
    "chunk" => 13,
)

struct SummaryConfig
    max_targets_per_batch::Int
    max_prompt_chars::Int
    max_children_per_target::Int
    max_witness_chars::Int
    max_readme_chars::Int
end

const DEFAULT_SUMMARY_CONFIG = SummaryConfig(16, 12000, 24, 400, 3000)

mutable struct ReplSession
    workspace::String
    db::CodeTreeDB
    summary_config::SummaryConfig
end

struct TreeIndex
    code_df::DataFrame
    row_by_id::Dict{String,Int}
    children_by_parent::Dict{String,Vector{String}}
    root_id::String
end

const _session_ref = Ref{Union{Nothing,ReplSession}}(nothing)
const _summary_transport_ref = Ref{Any}(nothing)

include("SevenAigentREPL/Display.jl")
include("SevenAigentREPL/Todo.jl")

"""
    bind!(workspace, db) -> Nothing

Initialise the REPL session for the given `workspace` and `db`.
Resets `Main.todo` to an empty DataFrame and clears any custom summary transport.
"""
function bind!(workspace::AbstractString, db::CodeTreeDB)::Nothing
    workspace_path = abspath(String(workspace))
    cfg = _load_summary_config(workspace_path)
    _session_ref[] = ReplSession(
        workspace_path,
        db,
        cfg,
    )
    _summary_transport_ref[] = nothing
    let df = DataFrame(id=Int[], description=String[], status=TodoStatus[])
        Core.eval(Main, :(todo = $df))
    end
    return nothing
end

"""
    summary_config() -> SummaryConfig

Return the summary configuration for the current session.
"""
function summary_config()::SummaryConfig
    return _require_session().summary_config
end

"""
    generated_summaries() -> DataFrame

Return all node ids that have an overridden summary in the current session.
"""
function generated_summaries()::DataFrame
    store = _summary_overrides(_require_session().db)
    ids = sort([id for (id, summary) in pairs(store) if !ismissing(summary)])
    return DataFrame(id = ids, summary = [store[id] for id in ids])
end

"""
    set_summary_transport!(transport) -> Nothing

Override the summary RPC transport with a custom callable (for testing).
"""
function set_summary_transport!(transport)::Nothing
    _summary_transport_ref[] = transport
    return nothing
end

"""
    clear_summary_transport!() -> Nothing

Restore the default IJulia Comm-based summary transport.
"""
function clear_summary_transport!()::Nothing
    _summary_transport_ref[] = nothing
    return nothing
end

function _require_session()::ReplSession
    isnothing(_session_ref[]) && throw(ErrorException("SevenAigentREPL.bind!(workspace, db) has not been called"))
    return _session_ref[]::ReplSession
end

function _load_summary_config(workspace::String)::SummaryConfig
    cfg_path = joinpath(workspace, ".7aigent", "config.toml")
    isfile(cfg_path) || return DEFAULT_SUMMARY_CONFIG

    parsed = TOML.parsefile(cfg_path)
    summaries = get(parsed, "summaries", Dict{String,Any}())
    summaries isa AbstractDict || return DEFAULT_SUMMARY_CONFIG

    return SummaryConfig(
        _summary_setting(summaries, "max_targets_per_batch", DEFAULT_SUMMARY_CONFIG.max_targets_per_batch),
        _summary_setting(summaries, "max_prompt_chars", DEFAULT_SUMMARY_CONFIG.max_prompt_chars),
        _summary_setting(summaries, "max_children_per_target", DEFAULT_SUMMARY_CONFIG.max_children_per_target),
        _summary_setting(summaries, "max_witness_chars", DEFAULT_SUMMARY_CONFIG.max_witness_chars),
        _summary_setting(summaries, "max_readme_chars", DEFAULT_SUMMARY_CONFIG.max_readme_chars),
    )
end

function _summary_setting(
    settings::AbstractDict,
    key::AbstractString,
    default::Int,
)::Int
    value = get(settings, key, default)
    value isa Integer && return Int(value)
    value isa AbstractFloat && return Int(round(value))
    return default
end

"""
    summarize!(ids; keywords) -> DataFrame

Request summaries for the given node ids. Returns a DataFrame with columns
`id`, `name`, and `summary` for each node whose summary was updated.
"""
function summarize!(ids; keywords = String[])::DataFrame
    session = _require_session()
    ordered_ids = _normalize_requested_ids(session.db, ids)
    isempty(ordered_ids) && return DataFrame(id = String[], name = String[], summary = String[])

    tree_index = _build_tree_index(session.db)
    normalized_keywords = _normalize_keywords(keywords)
    batches = _partition_targets(tree_index, ordered_ids, normalized_keywords, session.summary_config)

    updated = Set{String}()
    for batch_ids in batches
        request = _build_batch_request(tree_index, batch_ids, normalized_keywords, session; request_id = string(uuid4()))
        response = _request_summaries(request)
        for id in batch_ids
            summary_text = response[id]
            if !_summary_equals(_current_summary(session.db, id), summary_text)
                _set_summary!(session.db, id, summary_text)
                push!(updated, id)
            end
        end
    end

    result_ids = [id for id in ordered_ids if id in updated]
    return DataFrame(
        id = result_ids,
        name = [_row(tree_index, id).name for id in result_ids],
        summary = [coalesce(_current_summary(session.db, id), "") for id in result_ids],
    )
end

"""
    summarize!(frame; keywords) -> DataFrame

Variant that accepts a DataFrame with an `:id` column and back-fills any
`:summary` column in-place.
"""
function summarize!(frame::AbstractDataFrame; keywords = String[])::DataFrame
    hasproperty(frame, :id) || throw(ArgumentError("summarize! requires an :id column"))
    result = summarize!(collect(string.(frame.id)); keywords = keywords)
    if hasproperty(frame, :summary) && (frame isa DataFrame || frame isa SubDataFrame)
        summary_by_id = Dict(row.id => row.summary for row in eachrow(result))
        for i in 1:nrow(frame)
            id = string(frame[i, :id])
            haskey(summary_by_id, id) || continue
            frame[i, :summary] = summary_by_id[id]
        end
    end
    return result
end

include("SevenAigentREPL/Summarize.jl")

end # module
