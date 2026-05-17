module SevenAigentREPL

import CodeTree
using Base64
using DataFrames
using IJulia
using TOML
using UUIDs
using CodeTree: CodeTreeDB

export llm_show_dataframe, summarize!

const SUMMARY_COMM_TARGET = "7aigent.summary"
const SUMMARY_INPUT_PROMPT_PREFIX = "7aigent.summary.reply:"
const SUMMARY_RPC_TIMEOUT_SECS = 15.0

const LLM_DF_TRUNCATE = 360
const LLM_DF_MAX_DISPLAY_COLUMNS = 20
const LLM_DF_MAX_DISPLAY_WIDTH = LLM_DF_TRUNCATE * LLM_DF_MAX_DISPLAY_COLUMNS

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

function _llm_dataframe_io(io::IO, df::AbstractDataFrame)::IO
    rows, cols = displaysize(io)
    width = max(cols, LLM_DF_TRUNCATE * min(ncol(df), LLM_DF_MAX_DISPLAY_COLUMNS))
    return IOContext(
        io,
        :limit => true,
        :displaysize => (rows, min(width, LLM_DF_MAX_DISPLAY_WIDTH)),
    )
end

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

function llm_show_dataframe(
    df::AbstractDataFrame;
    kwargs...,
)::Nothing
    llm_show_dataframe(stdout, df; kwargs...)
    return nothing
end

function bind!(workspace::AbstractString, db::CodeTreeDB)::Nothing
    workspace_path = abspath(String(workspace))
    cfg = _load_summary_config(workspace_path)
    _session_ref[] = ReplSession(
        workspace_path,
        db,
        cfg,
    )
    _summary_transport_ref[] = nothing
    return nothing
end

function summary_config()::SummaryConfig
    return _require_session().summary_config
end

function generated_summaries()::DataFrame
    store = _summary_overrides(_require_session().db)
    ids = sort([id for (id, summary) in pairs(store) if !ismissing(summary)])
    return DataFrame(id = ids, summary = [store[id] for id in ids])
end

function set_summary_transport!(transport)::Nothing
    _summary_transport_ref[] = transport
    return nothing
end

function clear_summary_transport!()::Nothing
    _summary_transport_ref[] = nothing
    return nothing
end

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

function _normalize_requested_ids(db::CodeTreeDB, ids)::Vector{String}
    raw_ids = String[]
    for id in ids
        push!(raw_ids, string(id))
    end

    seen = Set{String}()
    ordered = String[]
    code_df = getfield(db.code, :_df)
    existing = Set(String.(code_df.id))
    for id in raw_ids
        id in seen && continue
        id in existing || throw(ArgumentError("Node '$id' not found in db.code"))
        push!(seen, id)
        push!(ordered, id)
    end
    return ordered
end

function _normalize_keywords(keywords)::Vector{String}
    seen = Set{String}()
    normalized = String[]
    for keyword in keywords
        text = lowercase(strip(string(keyword)))
        isempty(text) && continue
        text in seen && continue
        push!(seen, text)
        push!(normalized, text)
    end
    return normalized
end

function _build_tree_index(db::CodeTreeDB)::TreeIndex
    code_df = getfield(db.code, :_df)
    row_by_id = Dict{String,Int}()
    children_by_parent = Dict{String,Vector{String}}()
    root_id = ""

    for (i, row) in enumerate(eachrow(code_df))
        id = string(row.id)
        row_by_id[id] = i
        if ismissing(row.parent)
            root_id = id
        else
            parent_id = string(row.parent)
            push!(get!(children_by_parent, parent_id, String[]), id)
        end
    end

    for ids in values(children_by_parent)
        sort!(ids, by = id -> _row_by_id(code_df, row_by_id, id).sibling_order)
    end

    return TreeIndex(code_df, row_by_id, children_by_parent, root_id)
end

@inline function _row(tree_index::TreeIndex, id::String)
    return tree_index.code_df[tree_index.row_by_id[id], :]
end

@inline function _row_by_id(code_df::DataFrame, row_by_id::Dict{String,Int}, id::String)
    return code_df[row_by_id[id], :]
end

function _sort_key(tree_index::TreeIndex, id::String)::String
    parts = String[]
    current = id
    while true
        row = _row(tree_index, current)
        pushfirst!(parts, lpad(string(Int(row.sibling_order)), 6, '0'))
        parent_id = row.parent
        ismissing(parent_id) && break
        current = string(parent_id)
    end
    return join(parts, ".")
end

function _sort_ids(tree_index::TreeIndex, ids::Vector{String})::Vector{String}
    return sort(copy(ids), by = id -> _sort_key(tree_index, id))
end

function _is_descendant_or_self(tree_index::TreeIndex, node_id::String, ancestor_id::String)::Bool
    current = node_id
    while true
        current == ancestor_id && return true
        parent_id = _row(tree_index, current).parent
        ismissing(parent_id) && return false
        current = string(parent_id)
    end
end

function _partition_targets(
    tree_index::TreeIndex,
    requested_ids::Vector{String},
    keywords::Vector{String},
    cfg::SummaryConfig,
)::Vector{Vector{String}}
    requested_set = Set(requested_ids)
    return _partition_under(tree_index, tree_index.root_id, requested_set, keywords, cfg)
end

function _partition_under(
    tree_index::TreeIndex,
    node_id::String,
    requested_set::Set{String},
    keywords::Vector{String},
    cfg::SummaryConfig,
)::Vector{Vector{String}}
    ordered_entries = Vector{Vector{String}}()

    if node_id in requested_set
        push!(ordered_entries, [node_id])
    end

    for child_id in get(tree_index.children_by_parent, node_id, String[])
        child_targets = String[]
        for target_id in requested_set
            _is_descendant_or_self(tree_index, target_id, child_id) || continue
            push!(child_targets, target_id)
        end
        isempty(child_targets) && continue

        sorted_targets = _sort_ids(tree_index, child_targets)
        if _batch_fits(tree_index, sorted_targets, keywords, cfg)
            push!(ordered_entries, sorted_targets)
        else
            if length(sorted_targets) == 1
                throw(ErrorException(
                    "Target '$(only(sorted_targets))' exceeds summary batch limits even on its own."
                ))
            end
            append!(
                ordered_entries,
                _partition_under(tree_index, child_id, requested_set, keywords, cfg),
            )
        end
    end

    return _merge_adjacent_batches(tree_index, ordered_entries, keywords, cfg)
end

function _merge_adjacent_batches(
    tree_index::TreeIndex,
    batches::Vector{Vector{String}},
    keywords::Vector{String},
    cfg::SummaryConfig,
)::Vector{Vector{String}}
    merged = Vector{Vector{String}}()
    for batch_ids in batches
        if !isempty(merged)
            combined = _sort_ids(tree_index, vcat(merged[end], batch_ids))
            if _batch_fits(tree_index, combined, keywords, cfg)
                merged[end] = combined
                continue
            end
        end
        push!(merged, batch_ids)
    end
    return merged
end

function _batch_fits(
    tree_index::TreeIndex,
    batch_ids::Vector{String},
    keywords::Vector{String},
    cfg::SummaryConfig,
)::Bool
    length(batch_ids) <= cfg.max_targets_per_batch || return false
    request = _build_batch_request(tree_index, batch_ids, keywords, _require_session(); request_id = "estimate")
    return length(sprint(show, request)) <= cfg.max_prompt_chars
end

function _build_batch_request(
    tree_index::TreeIndex,
    batch_ids::Vector{String},
    keywords::Vector{String},
    session::ReplSession;
    request_id::String,
)
    node_cards = Dict{String,Any}()
    witnesses = Dict{String,Any}()
    targets = Any[]

    for target_id in batch_ids
        _ensure_node_card!(node_cards, session, tree_index, target_id)

        selected_children, overflow = _selected_children(session, tree_index, target_id, keywords)
        for child_id in selected_children
            _ensure_node_card!(node_cards, session, tree_index, child_id)
        end

        primary_leaf = _primary_witness_node_id(tree_index, target_id)
        primary_witness_id = "primary:" * primary_leaf
        _ensure_witness!(
            witnesses,
            primary_witness_id,
            (
                id = primary_witness_id,
                node_id = primary_leaf,
                role = "primary",
                text = _truncate_text(
                    CodeTree.get_source(session.db, primary_leaf),
                    session.summary_config.max_witness_chars,
                ),
            ),
        )

        promoted_readme_id = missing
        promoted_readme_child_ids = String[]
        promoted_readme_witness_id = missing
        readme_id = _readme_child_id(tree_index, target_id)
        if !ismissing(readme_id)
            promoted_readme_id = readme_id
            _ensure_node_card!(node_cards, session, tree_index, readme_id)
            promoted_readme_child_ids = get(tree_index.children_by_parent, readme_id, String[])
            for child_id in promoted_readme_child_ids
                _ensure_node_card!(node_cards, session, tree_index, child_id)
            end

            promoted_readme_witness_id = "readme:" * string(readme_id)
            _ensure_witness!(
                witnesses,
                promoted_readme_witness_id,
                (
                    id = promoted_readme_witness_id,
                    node_id = string(readme_id),
                    role = "readme",
                    text = _readme_witness_text(session, tree_index, string(readme_id)),
                ),
            )
        end

        push!(
            targets,
            (
                id = target_id,
                self_card_id = target_id,
                child_ids = selected_children,
                primary_witness_id = primary_witness_id,
                promoted_readme_id = promoted_readme_id,
                promoted_readme_child_ids = promoted_readme_child_ids,
                promoted_readme_witness_id = promoted_readme_witness_id,
                overflow = overflow,
            ),
        )
    end

    return (
        request_id = request_id,
        target_ids = batch_ids,
        evidence = (
            nodes = sort(collect(values(node_cards)), by = item -> item.id),
            witnesses = sort(collect(values(witnesses)), by = item -> item.id),
            targets = targets,
        ),
    )
end

function _ensure_node_card!(
    node_cards::Dict{String,Any},
    session::ReplSession,
    tree_index::TreeIndex,
    node_id::String,
)::Nothing
    haskey(node_cards, node_id) && return nothing
    row = _row(tree_index, node_id)
    node_cards[node_id] = (
        id = node_id,
        kind = string(row.kind),
        name = string(row.name),
        qname = row.qname,
        file = row.file,
        language = row.language,
        signature = row.signature,
        n_children = Int(row.n_children),
        n_lines = row.n_lines,
        summary = _effective_summary(session, tree_index, node_id),
    )
    return nothing
end

function _ensure_witness!(witnesses::Dict{String,Any}, witness_id::String, payload)::Nothing
    haskey(witnesses, witness_id) && return nothing
    witnesses[witness_id] = payload
    return nothing
end

function _effective_summary(
    session::ReplSession,
    tree_index::TreeIndex,
    node_id::String,
)::Union{String,Missing}
    overrides = _summary_overrides(session.db)
    if haskey(overrides, node_id)
        return overrides[node_id]
    end
    return _row(tree_index, node_id).summary
end

function _summary_overrides(db::CodeTreeDB)::Dict{String,Union{String,Missing}}
    return getfield(db.code, :_summary_overrides)
end

function _current_summary(db::CodeTreeDB, node_id::String)::Union{String,Missing}
    code_df = getfield(db.code, :_df)
    idx = findfirst(==(node_id), code_df.id)
    isnothing(idx) && throw(ArgumentError("Node '$node_id' not found in db.code"))
    return code_df[idx, :summary]
end

function _set_summary!(db::CodeTreeDB, node_id::String, summary_text::String)::Nothing
    code_df = getfield(db.code, :_df)
    idx = findfirst(==(node_id), code_df.id)
    isnothing(idx) && throw(ArgumentError("Node '$node_id' not found in db.code"))
    db.code[idx, :summary] = summary_text
    return nothing
end

function _summary_equals(current::Union{String,Missing}, new_text::String)::Bool
    return !ismissing(current) && current == new_text
end

function _selected_children(
    session::ReplSession,
    tree_index::TreeIndex,
    target_id::String,
    keywords::Vector{String},
)::Tuple{Vector{String},Union{Missing,NamedTuple}}
    children = get(tree_index.children_by_parent, target_id, String[])
    if length(children) <= session.summary_config.max_children_per_target
        return children, missing
    end

    scored = sort(
        copy(children),
        by = child_id -> _child_sort_tuple(session, tree_index, child_id, keywords),
    )
    limit = session.summary_config.max_children_per_target
    selected = scored[1:limit]
    omitted = scored[limit + 1:end]

    omitted_counts = Dict{String,Int}()
    for child_id in omitted
        kind = string(_row(tree_index, child_id).kind)
        omitted_counts[kind] = get(omitted_counts, kind, 0) + 1
    end

    overflow = (
        n_children_total = length(children),
        n_children_included = length(selected),
        n_children_omitted = length(omitted),
        omitted_by_kind = [
            (kind = kind, count = omitted_counts[kind])
            for kind in sort(collect(keys(omitted_counts)))
        ],
    )
    return selected, overflow
end

function _child_sort_tuple(
    session::ReplSession,
    tree_index::TreeIndex,
    child_id::String,
    keywords::Vector{String},
)
    row = _row(tree_index, child_id)
    child_kind = string(row.kind)
    child_name = string(row.name)
    child_summary = _effective_summary(session, tree_index, child_id)
    witness_source = _primary_witness_source(session, tree_index, child_id)
    distinct_matches, total_matches = _keyword_match_score(witness_source, keywords)
    return (
        child_name == "README.md" ? 0 : 1,
        ismissing(child_summary) ? 1 : 0,
        get(KIND_PRIORITY, child_kind, 99),
        -distinct_matches,
        -total_matches,
        -coalesce(row.n_lines, 0),
        Int(row.sibling_order),
        child_id,
    )
end

function _primary_witness_source(
    session::ReplSession,
    tree_index::TreeIndex,
    node_id::String,
)::String
    leaf_id = _primary_witness_node_id(tree_index, node_id)
    return _truncate_text(CodeTree.get_source(session.db, leaf_id), session.summary_config.max_witness_chars)
end

function _keyword_match_score(text::String, keywords::Vector{String})::Tuple{Int,Int}
    isempty(keywords) && return (0, 0)
    lowered = lowercase(text)
    distinct = 0
    total = 0
    for keyword in keywords
        occursin(keyword, lowered) || continue
        distinct += 1
        total += length(split(lowered, keyword)) - 1
    end
    return distinct, total
end

function _primary_witness_node_id(tree_index::TreeIndex, node_id::String)::String
    row = _row(tree_index, node_id)
    if Int(row.n_children) == 0
        return node_id
    end

    current = node_id
    while true
        children = get(tree_index.children_by_parent, current, String[])
        isempty(children) && return current
        current = first(children)
        Int(_row(tree_index, current).n_children) == 0 && return current
    end
end

function _readme_child_id(tree_index::TreeIndex, target_id::String)::Union{String,Missing}
    for child_id in get(tree_index.children_by_parent, target_id, String[])
        if string(_row(tree_index, child_id).name) == "README.md"
            return child_id
        end
    end
    return missing
end

function _readme_witness_text(
    session::ReplSession,
    tree_index::TreeIndex,
    readme_id::String,
)::String
    leaf_ids = _leaf_descendants(tree_index, readme_id)
    fragments = [CodeTree.get_source(session.db, leaf_id) for leaf_id in leaf_ids]
    return _truncate_text(join(fragments, "\n\n"), session.summary_config.max_readme_chars)
end

function _leaf_descendants(tree_index::TreeIndex, node_id::String)::Vector{String}
    row = _row(tree_index, node_id)
    if Int(row.n_children) == 0
        return [node_id]
    end

    leaves = String[]
    for child_id in get(tree_index.children_by_parent, node_id, String[])
        append!(leaves, _leaf_descendants(tree_index, child_id))
    end
    return leaves
end

function _truncate_text(text::String, max_chars::Int)::String
    length(text) <= max_chars && return text
    return text[1:max_chars] * "..."
end

function _request_summaries(request)::Dict{String,String}
    transport = _summary_transport_ref[]
    if !isnothing(transport)
        return _coerce_summary_response(transport(request), request.target_ids)
    end
    return _request_summaries_via_comm(request)
end

function _request_summaries_via_comm(request)::Dict{String,String}
    comm_id = string(uuid4())
    comm = IJulia.Comm(
        Symbol(SUMMARY_COMM_TARGET),
        comm_id,
        true,
        _ -> nothing,
        _ -> nothing;
        data = _wireify(request),
    )

    try
        prompt = SUMMARY_INPUT_PROMPT_PREFIX * comm_id
        response_task = @async IJulia.readprompt(prompt)
        wait_status = timedwait(() -> istaskdone(response_task), SUMMARY_RPC_TIMEOUT_SECS)
        if wait_status != :ok
            Base.throwto(response_task, InterruptException())
            throw(ErrorException("Summary RPC timed out waiting for frontend response."))
        end

        payload = fetch(response_task)
        return _coerce_stdin_response(payload, request.target_ids)
    finally
        try
            IJulia.close_comm(comm)
        catch
        end
    end
end

function _coerce_stdin_response(payload, target_ids::Vector{String})::Dict{String,String}
    payload isa AbstractString || throw(ErrorException("Summary RPC returned a non-string stdin payload."))
    lines = split(String(payload), '\n'; keepempty = false)
    isempty(lines) && throw(ErrorException("Summary RPC returned an empty stdin payload."))

    header = first(lines)
    if startswith(header, "error\t")
        encoded = split(header, '\t'; limit = 2)[2]
        throw(ErrorException(String(base64decode(encoded))))
    end
    header == "ok" || throw(ErrorException("Summary RPC returned a malformed stdin payload header."))

    summary_pairs = Dict{String,String}()
    for line in Iterators.drop(lines, 1)
        fields = split(line, '\t'; limit = 2)
        length(fields) == 2 || throw(ErrorException("Summary RPC returned a malformed stdin summary entry."))
        id, encoded_summary = fields
        summary_pairs[id] = String(base64decode(encoded_summary))
    end

    return _coerce_summary_response(summary_pairs, target_ids)
end

function _coerce_wire_response(payload, target_ids::Vector{String})::Dict{String,String}
    payload isa AbstractDict || throw(ErrorException("Summary RPC returned an invalid response payload."))

    if haskey(payload, "error")
        throw(ErrorException(string(payload["error"])))
    end

    if haskey(payload, "summaries")
        summary_pairs = Dict{String,String}()
        for entry in payload["summaries"]
            entry isa AbstractDict || throw(ErrorException("Summary RPC returned a malformed summary entry."))
            id = string(entry["id"])
            summary = string(entry["summary"])
            summary_pairs[id] = summary
        end
        return _coerce_summary_response(summary_pairs, target_ids)
    end

    return _coerce_summary_response(payload, target_ids)
end

function _coerce_summary_response(response, target_ids::Vector{String})::Dict{String,String}
    normalized = Dict{String,String}()

    if response isa AbstractDict
        for (id, summary) in pairs(response)
            normalized[string(id)] = string(summary)
        end
    else
        throw(ErrorException("Summary transport returned an unsupported response type."))
    end

    for id in target_ids
        haskey(normalized, id) || throw(ErrorException("Summary response omitted requested id '$id'."))
    end
    return Dict(id => normalized[id] for id in target_ids)
end

function _wireify(value)
    if value isa NamedTuple
        return Dict(string(k) => _wireify(v) for (k, v) in pairs(value))
    elseif value isa AbstractVector
        return [_wireify(item) for item in value]
    elseif value isa AbstractDict
        return Dict(string(k) => _wireify(v) for (k, v) in value)
    elseif value isa Missing
        return nothing
    else
        return value
    end
end

end # module
