struct GitRepoScope
    repo_root::String
    scope_path::String
end

struct GitDiffStatus
    path::String
    old_path::Union{String,Missing}
    status::String
end

struct GitPorcelainStatus
    path::String
    old_path::Union{String,Missing}
    git_has_staged::Bool
    git_has_unstaged::Bool
    is_untracked::Bool
    is_unmerged::Bool
end

struct GitFileChange
    path::String
    old_path::Union{String,Missing}
    status::String
    is_binary::Bool
    is_indexed::Bool
    git_has_staged::Bool
    git_has_unstaged::Bool
end

struct GitSelectionPlan
    path::String
    old_path::Union{String,Missing}
    whole_file::Bool
    node_ids::Vector{String}
    selectors::Vector{String}
end

function git_file_status(db::CodeTreeDB; phase::Symbol = :all)::DataFrame
    normalized_phase = _normalize_git_phase(phase)
    scope = _require_git_repo_scope(db, "git_file_status")
    changes = _collect_git_changes(db, scope)
    rows = _git_rows_for_phase(changes, normalized_phase)

    n = length(rows)
    path_col = Vector{String}(undef, n)
    db_file_col = Vector{String}(undef, n)
    old_path_col = Vector{Union{String,Missing}}(undef, n)
    status_col = Vector{String}(undef, n)
    is_binary_col = Vector{Bool}(undef, n)
    is_indexed_col = Vector{Bool}(undef, n)
    git_has_staged_col = Vector{Bool}(undef, n)
    git_has_unstaged_col = Vector{Bool}(undef, n)

    for (i, row) in enumerate(rows)
        path_col[i] = row.path
        db_file_col[i] = _repo_path_to_db_file(scope, row.path)
        old_path_col[i] = row.old_path
        status_col[i] = row.status
        is_binary_col[i] = row.is_binary
        is_indexed_col[i] = row.is_indexed
        git_has_staged_col[i] = row.git_has_staged
        git_has_unstaged_col[i] = row.git_has_unstaged
    end

    return DataFrame(
        path = path_col,
        db_file = db_file_col,
        old_path = old_path_col,
        status = status_col,
        is_binary = is_binary_col,
        is_indexed = is_indexed_col,
        git_has_staged = git_has_staged_col,
        git_has_unstaged = git_has_unstaged_col,
    )
end

function git_diff(db::CodeTreeDB, selector::AbstractString; phase::Symbol = :all)::String
    return git_diff(db, [String(selector)]; phase=phase)
end

function git_diff(
    db::CodeTreeDB,
    selectors::AbstractVector{<:AbstractString};
    phase::Symbol = :all,
)::String
    normalized_phase = _normalize_git_phase(phase)
    isempty(selectors) && throw(ArgumentError("git_diff requires at least one selector"))

    scope = _require_git_repo_scope(db, "git_diff")
    changes = _collect_git_changes(db, scope)
    phase_rows = _git_rows_for_phase(changes, normalized_phase)
    phase_by_path = Dict(row.path => row for row in phase_rows)
    all_by_path = Dict(row.path => row for row in changes.all_rows)
    plans = _resolve_git_selection_plans(db, scope, selectors, all_by_path)

    patches = String[]
    blocked_selectors = String[]
    for plan in plans
        phase_row = get(phase_by_path, plan.path, nothing)
        if plan.whole_file
            if isnothing(phase_row)
                continue
            end
            if phase_row.status == "unmerged" || phase_row.is_binary
                append!(blocked_selectors, plan.selectors)
                continue
            end
            patch = _render_whole_file_patch(db, scope, plan, phase_row, normalized_phase)
        else
            patch = _render_partial_patch(db, scope, plan, normalized_phase, phase_row)
        end
        isempty(patch) || push!(patches, patch)
    end

    if !isempty(blocked_selectors)
        unique_blocked = sort(unique(blocked_selectors))
        joined = join(["'$(selector)'" for selector in unique_blocked], ", ")
        throw(ErrorException("git_diff cannot render binary or unmerged selections: $(joined)"))
    end

    return join(patches, "\n")
end

function _git_write_plan_text(
    db::CodeTreeDB,
    selectors::AbstractVector{<:AbstractString},
)::String
    isempty(selectors) &&
        throw(ArgumentError("_git_write_plan_text requires at least one selector"))

    scope = _require_git_repo_scope(db, "_git_write_plan_text")
    changes = _collect_git_changes(db, scope)
    all_by_path = Dict(row.path => row for row in changes.all_rows)
    unstaged_by_path = Dict(row.path => row for row in changes.unstaged_rows)
    plans = _resolve_git_selection_plans(db, scope, selectors, all_by_path)

    lines = String[]
    partial_all_patches = String[]
    partial_unstaged_patches = String[]
    blocked_selectors = String[]

    for plan in plans
        if plan.whole_file
            change = get(all_by_path, plan.path, nothing)
            if !isnothing(change) && change.status == "unmerged"
                append!(blocked_selectors, plan.selectors)
                continue
            end

            old_path = ismissing(plan.old_path) ? "" : String(plan.old_path)
            push!(
                lines,
                "WHOLE\t$(_hex_encode(plan.path))\t$(_hex_encode(old_path))",
            )
            continue
        end

        all_patch = _render_partial_patch(
            db,
            scope,
            plan,
            :all,
            get(all_by_path, plan.path, nothing),
        )
        isempty(all_patch) || push!(partial_all_patches, all_patch)

        unstaged_patch = _render_partial_patch(
            db,
            scope,
            plan,
            :unstaged,
            get(unstaged_by_path, plan.path, nothing),
        )
        isempty(unstaged_patch) || push!(partial_unstaged_patches, unstaged_patch)
    end

    if !isempty(blocked_selectors)
        unique_blocked = sort(unique(blocked_selectors))
        joined = join(["'$(selector)'" for selector in unique_blocked], ", ")
        throw(ErrorException("_git_write_plan_text cannot plan unmerged selections: $(joined)"))
    end

    push!(lines, "PARTIAL_ALL\t$(_hex_encode(join(partial_all_patches, "\n")))")
    push!(
        lines,
        "PARTIAL_UNSTAGED\t$(_hex_encode(join(partial_unstaged_patches, "\n")))",
    )
    return join(lines, "\n")
end

_hex_encode(str::String)::String = bytes2hex(codeunits(str))

function _refresh_git_overlay!(db::CodeTreeDB)::Nothing
    code_df = getfield(db.code, :_df)
    _ensure_git_overlay_columns!(code_df)

    for row in eachrow(code_df)
        row.git_status = "clean"
        row.git_has_staged = false
        row.git_has_unstaged = false
    end

    scope = _git_repo_scope(db)
    ismissing(scope) && return nothing

    changes = _collect_git_changes(db, scope)
    all_by_path = Dict(row.path => row for row in changes.all_rows)
    staged_by_path = Dict(row.path => row for row in changes.staged_rows)
    unstaged_by_path = Dict(row.path => row for row in changes.unstaged_rows)

    file_ids_by_repo_path = _file_ids_by_repo_path(db, scope)
    module_ids_by_prefix = _module_ids_by_prefix(db)
    codebase_ids = _codebase_ids(db)

    for (path, change) in staged_by_path
        for id in _phase_changed_node_ids(db, scope, path, change, :staged, file_ids_by_repo_path)
            _mark_git_phase!(code_df, id, change.status, :staged)
        end
    end

    for (path, change) in unstaged_by_path
        for id in _phase_changed_node_ids(db, scope, path, change, :unstaged, file_ids_by_repo_path)
            _mark_git_phase!(code_df, id, change.status, :unstaged)
        end
    end

    for (path, change) in all_by_path
        db_file = _repo_path_to_db_file(scope, path)
        for (prefix, ids) in module_ids_by_prefix
            if db_file == prefix || startswith(db_file, prefix * "/")
                for id in ids
                    _merge_git_overlay!(code_df, id, change)
                end
            end
        end
        for id in codebase_ids
            _merge_git_overlay!(code_df, id, change)
        end
    end

    return nothing
end

function _phase_changed_node_ids(
    db::CodeTreeDB,
    scope::GitRepoScope,
    path::String,
    change::GitFileChange,
    phase::Symbol,
    file_ids_by_repo_path::Dict{String,Vector{String}},
)::Vector{String}
    db_file = _repo_path_to_db_file(scope, path)
    file_ids = get(file_ids_by_repo_path, db_file, String[])
    isempty(file_ids) && return String[]

    if change.status in ("added", "deleted", "renamed", "copied", "type_changed", "untracked", "unmerged") ||
       change.is_binary ||
       !change.is_indexed
        return file_ids
    end

    base_src = phase == :unstaged ? _index_file_text(scope, path) : _head_file_text(scope, path)
    target_src = phase == :staged ? _index_file_text(scope, path) : _worktree_file_text(db, scope, path)
    if ismissing(base_src) || ismissing(target_src)
        return file_ids
    end

    base_rows = _build_file_rows_for_update(db, FilePath(db_file), String(base_src))
    target_rows = phase == :staged ?
        _build_file_rows_for_update(db, FilePath(db_file), String(target_src)) :
        nothing

    changed_ids = String[]
    for id in file_ids
        base_node_src = _row_source(base_rows, String(base_src), id)
        target_node_src = if phase == :staged
            _row_source(target_rows, String(target_src), id)
        else
            _db_row_source(db, db_file, id)
        end

        if ismissing(base_node_src) || ismissing(target_node_src)
            return file_ids
        end
        if String(base_node_src) != String(target_node_src)
            push!(changed_ids, id)
        end
    end
    return changed_ids
end

function _mark_git_phase!(
    code_df::DataFrame,
    id::String,
    status::String,
    phase::Symbol,
)::Nothing
    idx = findfirst(==(id), code_df.id)
    isnothing(idx) && return nothing

    code_df[idx, :git_status] = _merge_git_status(code_df[idx, :git_status], status)
    if phase == :staged
        code_df[idx, :git_has_staged] = true
    else
        code_df[idx, :git_has_unstaged] = true
    end
    return nothing
end

function _set_git_overlay!(
    code_df::DataFrame,
    id::String,
    change::GitFileChange,
)::Nothing
    idx = findfirst(==(id), code_df.id)
    isnothing(idx) && return nothing
    code_df[idx, :git_status] = change.status
    code_df[idx, :git_has_staged] = change.git_has_staged
    code_df[idx, :git_has_unstaged] = change.git_has_unstaged
    return nothing
end

function _merge_git_overlay!(
    code_df::DataFrame,
    id::String,
    change::GitFileChange,
)::Nothing
    idx = findfirst(==(id), code_df.id)
    isnothing(idx) && return nothing

    current_status = code_df[idx, :git_status]
    current_staged = code_df[idx, :git_has_staged]
    current_unstaged = code_df[idx, :git_has_unstaged]

    code_df[idx, :git_status] = _merge_git_status(current_status, "modified")
    code_df[idx, :git_has_staged] = current_staged || change.git_has_staged
    code_df[idx, :git_has_unstaged] = current_unstaged || change.git_has_unstaged
    return nothing
end

function _merge_git_status(current::String, incoming::String)::String
    current == "clean" && return incoming
    current == incoming && return current
    return "modified"
end

function _file_ids_by_repo_path(
    db::CodeTreeDB,
    scope::GitRepoScope,
)::Dict{String,Vector{String}}
    code_df = getfield(db.code, :_df)
    result = Dict{String,Vector{String}}()
    for row in eachrow(code_df)
        ismissing(row.file) && continue
        repo_path = _db_file_to_repo_path(scope, row.file)
        push!(get!(result, repo_path, String[]), row.id)
    end
    return result
end

function _module_ids_by_prefix(db::CodeTreeDB)::Dict{String,Vector{String}}
    code_df = getfield(db.code, :_df)
    result = Dict{String,Vector{String}}()
    for row in eachrow(code_df)
        row.kind == "module" || continue
        push!(get!(result, row.id, String[]), row.id)
    end
    return result
end

function _codebase_ids(db::CodeTreeDB)::Vector{String}
    code_df = getfield(db.code, :_df)
    return collect(String.(code_df.id[code_df.kind .== "codebase"]))
end

function _git_rows_for_phase(
    changes::NamedTuple{(:all_rows, :staged_rows, :unstaged_rows)},
    phase::Symbol,
)::Vector{GitFileChange}
    phase == :all && return changes.all_rows
    phase == :staged && return changes.staged_rows
    return changes.unstaged_rows
end

function _collect_git_changes(
    db::CodeTreeDB,
    scope::GitRepoScope,
)::NamedTuple{(:all_rows, :staged_rows, :unstaged_rows),Tuple{Vector{GitFileChange},Vector{GitFileChange},Vector{GitFileChange}}}
    staged_status = _git_diff_status(scope, :staged)
    unstaged_status = _git_diff_status(scope, :unstaged)
    all_status = _git_diff_status(scope, :all)

    staged_binary = _git_binary_paths(scope, :staged)
    unstaged_binary = _git_binary_paths(scope, :unstaged)
    all_binary = _git_binary_paths(scope, :all)

    porcelain = _git_porcelain_status(scope)
    indexed_paths = _indexed_repo_paths(db, scope)

    all_rows = _build_phase_git_rows(
        scope,
        indexed_paths,
        all_status,
        all_binary,
        porcelain,
        Set(keys(staged_status)),
        union(Set(keys(unstaged_status)), _untracked_paths(porcelain)),
        :all,
    )
    staged_rows = _build_phase_git_rows(
        scope,
        indexed_paths,
        staged_status,
        staged_binary,
        porcelain,
        Set(keys(staged_status)),
        union(Set(keys(unstaged_status)), _untracked_paths(porcelain)),
        :staged,
    )
    unstaged_rows = _build_phase_git_rows(
        scope,
        indexed_paths,
        unstaged_status,
        unstaged_binary,
        porcelain,
        Set(keys(staged_status)),
        union(Set(keys(unstaged_status)), _untracked_paths(porcelain)),
        :unstaged,
    )
    return (all_rows = all_rows, staged_rows = staged_rows, unstaged_rows = unstaged_rows)
end

function _build_phase_git_rows(
    scope::GitRepoScope,
    indexed_paths::Set{String},
    diff_status::Dict{String,GitDiffStatus},
    binary_paths::Set{String},
    porcelain::Dict{String,GitPorcelainStatus},
    staged_paths::Set{String},
    unstaged_paths::Set{String},
    phase::Symbol,
)::Vector{GitFileChange}
    selected_paths = Set(keys(diff_status))

    for (path, entry) in porcelain
        if entry.is_untracked && phase in (:all, :unstaged)
            push!(selected_paths, path)
        elseif entry.is_unmerged
            include_path =
                phase == :all ||
                (phase == :staged && entry.git_has_staged) ||
                (phase == :unstaged && entry.git_has_unstaged)
            include_path && push!(selected_paths, path)
        end
    end

    rows = GitFileChange[]
    for path in sort!(collect(selected_paths))
        entry = get(porcelain, path, nothing)
        if !isnothing(entry) && entry.is_unmerged
            push!(rows, GitFileChange(
                path,
                missing,
                "unmerged",
                false,
                path in indexed_paths,
                entry.git_has_staged || path in staged_paths,
                entry.git_has_unstaged || path in unstaged_paths,
            ))
            continue
        end

        if !isnothing(entry) && entry.is_untracked && phase in (:all, :unstaged)
            push!(rows, GitFileChange(
                path,
                missing,
                "untracked",
                _is_binary_file(joinpath(scope.repo_root, path)),
                false,
                false,
                true,
            ))
            continue
        end

        diff_entry = get(diff_status, path, nothing)
        isnothing(diff_entry) && continue
        push!(rows, GitFileChange(
            diff_entry.path,
            diff_entry.old_path,
            diff_entry.status,
            diff_entry.path in binary_paths,
            diff_entry.path in indexed_paths,
            diff_entry.path in staged_paths,
            diff_entry.path in unstaged_paths,
        ))
    end
    return rows
end

function _untracked_paths(porcelain::Dict{String,GitPorcelainStatus})::Set{String}
    result = Set{String}()
    for (path, entry) in porcelain
        entry.is_untracked && push!(result, path)
    end
    return result
end

function _indexed_repo_paths(db::CodeTreeDB, scope::GitRepoScope)::Set{String}
    code_df = getfield(db.code, :_df)
    files = skipmissing(code_df.file)
    return Set(_db_file_to_repo_path(scope, file) for file in files)
end

function _resolve_git_selection_plans(
    db::CodeTreeDB,
    scope::GitRepoScope,
    selectors::AbstractVector{<:AbstractString},
    all_by_path::Dict{String,GitFileChange},
)::Vector{GitSelectionPlan}
    code_df = getfield(db.code, :_df)
    known_ids = Set(String.(code_df.id))
    whole_file_paths = Set{String}()
    node_ids_by_path = Dict{String,Set{String}}()
    selector_sets = Dict{String,Set{String}}()
    old_path_by_path = Dict{String,Union{String,Missing}}()
    unknown_selectors = String[]

    function add_whole_file!(path::String, selector::String)::Nothing
        push!(whole_file_paths, path)
        delete!(node_ids_by_path, path)
        push!(get!(selector_sets, path, Set{String}()), selector)
        if haskey(all_by_path, path)
            old_path_by_path[path] = all_by_path[path].old_path
        elseif !haskey(old_path_by_path, path)
            old_path_by_path[path] = missing
        end
        return nothing
    end

    function add_partial_node!(path::String, id::String, selector::String)::Nothing
        path in whole_file_paths && return nothing
        push!(get!(node_ids_by_path, path, Set{String}()), id)
        push!(get!(selector_sets, path, Set{String}()), selector)
        if haskey(all_by_path, path)
            old_path_by_path[path] = all_by_path[path].old_path
        elseif !haskey(old_path_by_path, path)
            old_path_by_path[path] = missing
        end
        return nothing
    end

    for selector in unique(String.(selectors))
        if selector in known_ids
            idx = findfirst(==(selector), code_df.id)
            row = code_df[idx, :]
            if row.kind == "codebase"
                for path in keys(all_by_path)
                    add_whole_file!(path, selector)
                end
            elseif row.kind == "module"
                for path in keys(all_by_path)
                    db_file = _repo_path_to_db_file(scope, path)
                    if db_file == row.id || startswith(db_file, row.id * "/")
                        add_whole_file!(path, selector)
                    end
                end
            elseif row.kind == "file"
                add_whole_file!(_db_file_to_repo_path(scope, row.file), selector)
            else
                ismissing(row.file) && throw(ArgumentError("Node '$selector' has no file association"))
                repo_path = _db_file_to_repo_path(scope, row.file)
                change = get(all_by_path, repo_path, nothing)
                if !isnothing(change) && (
                    change.status in ("added", "deleted", "renamed", "copied", "type_changed", "untracked", "unmerged") ||
                    !change.is_indexed ||
                    change.is_binary
                )
                    add_whole_file!(repo_path, selector)
                else
                    add_partial_node!(repo_path, row.id, selector)
                end
            end
        elseif haskey(all_by_path, selector)
            add_whole_file!(selector, selector)
        else
            push!(unknown_selectors, selector)
        end
    end

    isempty(unknown_selectors) ||
        throw(ArgumentError("Unknown git selector(s): $(join(sort(unknown_selectors), ", "))"))

    plans = GitSelectionPlan[]
    for path in sort!(collect(union(whole_file_paths, Set(keys(node_ids_by_path)))))
        selectors_for_path = sort!(collect(get(selector_sets, path, Set{String}())))
        if path in whole_file_paths
            push!(plans, GitSelectionPlan(path, get(old_path_by_path, path, missing), true, String[], selectors_for_path))
            continue
        end
        pruned_node_ids = _prune_descendant_node_ids(db, collect(node_ids_by_path[path]))
        push!(plans, GitSelectionPlan(path, get(old_path_by_path, path, missing), false, pruned_node_ids, selectors_for_path))
    end
    return plans
end

function _prune_descendant_node_ids(db::CodeTreeDB, node_ids::Vector{String})::Vector{String}
    isempty(node_ids) && return String[]
    code_df = getfield(db.code, :_df)
    parent_by_id = Dict{String,Union{String,Missing}}()
    sort_keys = Dict{String,Tuple{Int,String,Int}}()
    for row in eachrow(code_df)
        id = String(row.id)
        parent_by_id[id] = row.parent
        sort_keys[id] = (
            Int(row.depth),
            ismissing(row.file) ? "" : String(row.file),
            ismissing(row.line_start) ? 0 : Int(row.line_start),
        )
    end

    sorted_ids = sort(unique(node_ids); by=id -> get(sort_keys, id, (typemax(Int), id, typemax(Int))))
    kept = String[]
    kept_set = Set{String}()
    for id in sorted_ids
        current = get(parent_by_id, id, missing)
        skip = false
        while !ismissing(current)
            if current in kept_set
                skip = true
                break
            end
            current = get(parent_by_id, String(current), missing)
        end
        skip && continue
        push!(kept, id)
        push!(kept_set, id)
    end
    return sort!(kept; by=id -> get(sort_keys, id, (typemax(Int), id, typemax(Int))))
end

function _render_whole_file_patch(
    db::CodeTreeDB,
    scope::GitRepoScope,
    plan::GitSelectionPlan,
    phase_row::GitFileChange,
    phase::Symbol,
)::String
    if phase_row.status == "untracked"
        new_src = _worktree_file_text(db, scope, plan.path)
        ismissing(new_src) && return ""
        return _render_unified_patch("/dev/null", "b/$(plan.path)", "", String(new_src))
    end

    pathspecs = ismissing(plan.old_path) ? [plan.path] : [String(plan.old_path), plan.path]
    args = if phase == :all
        ["diff", "--no-ext-diff", "--binary", "-M", "-C", "HEAD", "--"]
    elseif phase == :staged
        ["diff", "--no-ext-diff", "--binary", "--cached", "-M", "-C", "--"]
    else
        ["diff", "--no-ext-diff", "--binary", "-M", "-C", "--"]
    end

    diff = _git_output(scope, vcat(args, pathspecs); allow_failure=true)
    return isempty(diff) ? "" : diff
end

function _render_partial_patch(
    db::CodeTreeDB,
    scope::GitRepoScope,
    plan::GitSelectionPlan,
    phase::Symbol,
    phase_row::Union{GitFileChange,Nothing},
)::String
    db_file = _repo_path_to_db_file(scope, plan.path)
    base_src = phase == :unstaged ? _index_file_text(scope, plan.path) : _head_file_text(scope, plan.path)
    target_src = phase == :staged ? _index_file_text(scope, plan.path) : _worktree_file_text(db, scope, plan.path)

    ismissing(base_src) && return isnothing(phase_row) ? "" : _render_whole_file_patch(db, scope, plan, phase_row, phase)
    ismissing(target_src) && return isnothing(phase_row) ? "" : _render_whole_file_patch(db, scope, plan, phase_row, phase)

    base_rows = _build_file_rows_for_update(db, FilePath(db_file), String(base_src))
    target_rows = phase == :staged ?
        _build_file_rows_for_update(db, FilePath(db_file), String(target_src)) :
        nothing

    replacements = Tuple{Int,Int,String}[]
    for node_id in plan.node_ids
        span = _row_span(base_rows, node_id)
        isnothing(span) && return isnothing(phase_row) ? "" : _render_whole_file_patch(db, scope, plan, phase_row, phase)

        target_node_src = if phase == :staged
            _row_source(target_rows, String(target_src), node_id)
        else
            get_source(db, node_id)
        end
        ismissing(target_node_src) &&
            return isnothing(phase_row) ? "" : _render_whole_file_patch(db, scope, plan, phase_row, phase)
        push!(replacements, (span[1], span[2], String(target_node_src)))
    end

    sort!(replacements; by = replacement -> replacement[1], rev=true)
    selected_src = String(base_src)
    for (line_start, line_end, replacement_src) in replacements
        selected_src = _splice_lines(selected_src, line_start, line_end, replacement_src)
    end

    selected_src == String(base_src) && return ""
    return _render_unified_patch("a/$(plan.path)", "b/$(plan.path)", String(base_src), selected_src)
end

function _row_span(rows::Vector{CodeRow}, node_id::String)::Union{Tuple{Int,Int},Nothing}
    idx = findfirst(row -> row.id == node_id, rows)
    isnothing(idx) && return nothing
    row = rows[idx]
    if ismissing(row.line_start) || ismissing(row.line_end)
        return nothing
    end
    return (Int(row.line_start), Int(row.line_end))
end

function _row_source(
    rows::Vector{CodeRow},
    src::String,
    node_id::String,
)::Union{String,Missing}
    idx = findfirst(row -> row.id == node_id, rows)
    isnothing(idx) && return missing
    row = rows[idx]
    !ismissing(row.source) && return String(row.source)
    if ismissing(row.line_start) || ismissing(row.line_end)
        return missing
    end
    return _slice_lines_or_missing(src, Int(row.line_start), Int(row.line_end))
end

function _db_row_source(
    db::CodeTreeDB,
    db_file::String,
    node_id::String,
)::Union{String,Missing}
    code_df = getfield(db.code, :_df)
    idx = findfirst(==(node_id), code_df.id)
    isnothing(idx) && return missing
    row = code_df[idx, :]
    !ismissing(row.source) && return String(row.source)
    if ismissing(row.line_start) || ismissing(row.line_end)
        return missing
    end
    src = get(db._buffer, db_file, missing)
    ismissing(src) && return missing
    return _slice_lines_or_missing(String(src), Int(row.line_start), Int(row.line_end))
end

function _slice_lines_or_missing(src::String, line_start::Int, line_end::Int)::Union{String,Missing}
    lines = split(src, '\n')
    if !isempty(lines) && isempty(lines[end])
        pop!(lines)
    end
    if line_start < 1 || line_end < line_start || line_end > length(lines)
        return missing
    end
    return join(lines[line_start:line_end], '\n')
end

function _render_unified_patch(
    old_label::String,
    new_label::String,
    old_src::String,
    new_src::String,
)::String
    old_lines = _diff_lines(old_src)
    new_lines = _diff_lines(new_src)
    hunks = _compute_diff_hunks(old_lines, new_lines; context=3)
    isempty(hunks) && return ""

    io = IOBuffer()
    println(io, "--- $(old_label)")
    println(io, "+++ $(new_label)")
    for hunk in hunks
        old_range = hunk.old_count == 1 ? "$(hunk.old_start)" : "$(hunk.old_start),$(hunk.old_count)"
        new_range = hunk.new_count == 1 ? "$(hunk.new_start)" : "$(hunk.new_start),$(hunk.new_count)"
        println(io, "@@ -$(old_range) +$(new_range) @@")
        for line in hunk.lines
            println(io, line)
        end
    end
    return String(take!(io))
end

function _diff_lines(src::String)::Vector{String}
    isempty(src) && return String[]
    lines = split(src, '\n')
    if !isempty(lines) && isempty(lines[end])
        pop!(lines)
    end
    return lines
end

function _head_file_text(scope::GitRepoScope, path::String)::Union{String,Missing}
    return _git_show_file(scope, "HEAD", path)
end

function _index_file_text(scope::GitRepoScope, path::String)::Union{String,Missing}
    return _git_show_file(scope, "", path)
end

function _git_show_file(
    scope::GitRepoScope,
    treeish::String,
    path::String,
)::Union{String,Missing}
    spec = isempty(treeish) ? ":$(path)" : "$(treeish):$(path)"
    cmd = Cmd(Cmd(["git", "show", spec]); dir=scope.repo_root)
    try
        return read(pipeline(cmd; stderr=devnull), String)
    catch e
        _is_git_command_failure(e) || rethrow()
        return missing
    end
end

function _worktree_file_text(
    db::CodeTreeDB,
    scope::GitRepoScope,
    path::String,
)::Union{String,Missing}
    db_file = _repo_path_to_db_file(scope, path)
    if haskey(db._buffer, db_file)
        return db._buffer[db_file]
    end
    abs_path = joinpath(scope.repo_root, path)
    isfile(abs_path) || return missing
    try
        return read(abs_path, String)
    catch e
        _is_file_read_failure(e) || rethrow()
        return missing
    end
end

function _git_diff_status(scope::GitRepoScope, phase::Symbol)::Dict{String,GitDiffStatus}
    if phase == :all
        if _git_head_exists(scope)
            output = _git_output(
                scope,
                _with_scope_pathspec(scope, ["diff", "--name-status", "-z", "-M", "-C", "HEAD"]);
                allow_failure=false,
            )
            return _parse_name_status_z(output)
        end

        combined = copy(_git_diff_status(scope, :staged))
        merge!(combined, _git_diff_status(scope, :unstaged))
        return combined
    end

    args = if phase == :staged
        ["diff", "--cached", "--name-status", "-z", "-M", "-C"]
    else
        ["diff", "--name-status", "-z", "-M", "-C"]
    end
    output = _git_output(scope, _with_scope_pathspec(scope, args); allow_failure=false)
    return _parse_name_status_z(output)
end

function _git_binary_paths(scope::GitRepoScope, phase::Symbol)::Set{String}
    if phase == :all
        if _git_head_exists(scope)
            output = _git_output(
                scope,
                _with_scope_pathspec(scope, ["diff", "--numstat", "-z", "-M", "-C", "HEAD"]);
                allow_failure=false,
            )
            return _parse_numstat_binary_paths(output)
        end
        return union(_git_binary_paths(scope, :staged), _git_binary_paths(scope, :unstaged))
    end

    args = if phase == :staged
        ["diff", "--cached", "--numstat", "-z", "-M", "-C"]
    else
        ["diff", "--numstat", "-z", "-M", "-C"]
    end
    output = _git_output(scope, _with_scope_pathspec(scope, args); allow_failure=false)
    return _parse_numstat_binary_paths(output)
end

function _git_porcelain_status(scope::GitRepoScope)::Dict{String,GitPorcelainStatus}
    output = _git_output(scope, _with_scope_pathspec(scope, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]); allow_failure=false)
    return _parse_porcelain_z(output)
end

function _parse_name_status_z(output::String)::Dict{String,GitDiffStatus}
    result = Dict{String,GitDiffStatus}()
    tokens = _split_nul_tokens(output)
    i = 1
    while i <= length(tokens)
        status_token = tokens[i]
        code = split(status_token, '\t')[1]
        if startswith(code, "R") || startswith(code, "C")
            old_path = tokens[i + 1]
            new_path = tokens[i + 2]
            result[new_path] = GitDiffStatus(new_path, old_path, _map_name_status(code[1]))
            i += 3
        else
            path = tokens[i + 1]
            result[path] = GitDiffStatus(path, missing, _map_name_status(code[1]))
            i += 2
        end
    end
    return result
end

function _parse_numstat_binary_paths(output::String)::Set{String}
    result = Set{String}()
    tokens = _split_nul_tokens(output)
    i = 1
    while i <= length(tokens)
        fields = split(tokens[i], '\t')
        if length(fields) < 3
            i += 1
            continue
        end
        added = fields[1]
        deleted = fields[2]
        path = fields[3]
        if isempty(path)
            new_path = tokens[i + 2]
            if added == "-" || deleted == "-"
                push!(result, new_path)
            end
            i += 3
        else
            if added == "-" || deleted == "-"
                push!(result, path)
            end
            i += 1
        end
    end
    return result
end

function _parse_porcelain_z(output::String)::Dict{String,GitPorcelainStatus}
    result = Dict{String,GitPorcelainStatus}()
    tokens = _split_nul_tokens(output)
    i = 1
    while i <= length(tokens)
        token = tokens[i]
        length(token) >= 3 || break
        x = token[1]
        y = token[2]
        path = token[4:end]
        old_path = missing
        if x in ('R', 'C') || y in ('R', 'C')
            old_path = tokens[i + 1]
            i += 1
        end

        is_untracked = x == '?' && y == '?'
        is_unmerged = _is_unmerged_status(x, y)
        git_has_staged = !is_untracked && x != ' '
        git_has_unstaged = is_untracked || y != ' '
        result[path] = GitPorcelainStatus(
            path,
            old_path,
            git_has_staged,
            git_has_unstaged,
            is_untracked,
            is_unmerged,
        )
        i += 1
    end
    return result
end

function _is_unmerged_status(x::Char, y::Char)::Bool
    return string(x, y) in ("DD", "AU", "UD", "UA", "DU", "AA", "UU")
end

function _split_nul_tokens(output::String)::Vector{String}
    parts = split(output, '\0')
    return isempty(parts) ? String[] : filter(!isempty, parts)
end

function _map_name_status(code::Char)::String
    code == 'A' && return "added"
    code == 'D' && return "deleted"
    code == 'M' && return "modified"
    code == 'R' && return "renamed"
    code == 'C' && return "copied"
    code == 'T' && return "type_changed"
    code == 'U' && return "unmerged"
    throw(ErrorException("Unsupported git status code '$code'"))
end

function _with_scope_pathspec(scope::GitRepoScope, args::Vector{String})::Vector{String}
    isempty(scope.scope_path) && return args
    return vcat(args, ["--", scope.scope_path])
end

function _db_file_to_repo_path(scope::GitRepoScope, db_file::String)::String
    return isempty(scope.scope_path) ? db_file : _normalize_rel_path(joinpath(scope.scope_path, db_file))
end

function _repo_path_to_db_file(scope::GitRepoScope, repo_path::String)::String
    isempty(scope.scope_path) && return repo_path
    if repo_path == scope.scope_path
        return ""
    elseif startswith(repo_path, scope.scope_path * "/")
        return repo_path[length(scope.scope_path) + 2:end]
    end
    throw(ArgumentError("Path '$repo_path' is outside db.root"))
end

function _normalize_git_phase(phase::Symbol)::Symbol
    phase in (:all, :staged, :unstaged) && return phase
    throw(ArgumentError("Unsupported git phase '$phase'; expected :all, :staged, or :unstaged"))
end

function _require_git_repo_scope(db::CodeTreeDB, caller::String)::GitRepoScope
    scope = _git_repo_scope(db)
    ismissing(scope) &&
        throw(ErrorException("$(caller) requires db.root to be inside a git repository"))
    return scope
end

function _git_repo_scope(db::CodeTreeDB)::Union{GitRepoScope,Missing}
    output = try
        readchomp(pipeline(`git -C $(db.root) rev-parse --show-toplevel`; stderr=devnull))
    catch e
        _is_git_command_failure(e) || rethrow()
        return missing
    end

    repo_root = abspath(output)
    abs_root = abspath(db.root)
    if abs_root == repo_root
        return GitRepoScope(repo_root, "")
    end
    scope_path = _normalize_rel_path(relpath(abs_root, repo_root))
    return GitRepoScope(repo_root, scope_path)
end

function _git_output(
    scope::GitRepoScope,
    args::Vector{String};
    allow_failure::Bool,
)::String
    cmd = Cmd(Cmd(["git"; args]); dir=scope.repo_root)
    try
        return read(pipeline(cmd; stderr=devnull), String)
    catch e
        _is_git_command_failure(e) || rethrow()
        if allow_failure
            return ""
        end
        throw(ErrorException("git $(join(args, " ")) failed"))
    end
end

function _git_head_exists(scope::GitRepoScope)::Bool
    cmd = Cmd(Cmd(["git", "rev-parse", "--verify", "HEAD"]); dir=scope.repo_root)
    try
        read(pipeline(cmd; stderr=devnull), String)
        return true
    catch e
        _is_git_command_failure(e) || rethrow()
        return false
    end
end
