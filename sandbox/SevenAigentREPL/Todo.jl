# Todo.jl — Task tracking for the agent session

const TodoParent = Union{Missing, Int}
const TODO_COLUMNS = (:id, :parent, :description, :status)

"""
Represents the lifecycle status of a todo item.
"""
@enum TodoStatus pending in_progress done

struct TodoTree
    df::DataFrame
    row_by_id::Dict{Int, Int}
    parent_by_id::Dict{Int, TodoParent}
    children_by_parent::Dict{TodoParent, Vector{Int}}
    roots::Vector{Int}
    leaves_in_row_order::Vector{Int}
    active_ids::Vector{Int}
end

struct TodoValidation
    tree::Union{Nothing, TodoTree}
    errors::Vector{String}
end

function _empty_todo_df()::DataFrame
    return DataFrame(
        id = Int[],
        parent = TodoParent[],
        description = String[],
        status = TodoStatus[],
    )
end

function _main_todo_value()
    return isdefined(Main, :todo) ? getfield(Main, :todo) : nothing
end

function _validation_message(prefix::String, errors::Vector{String})::String
    return prefix * "\n" * join(["- $error" for error in errors], "\n")
end

function _normalize_int(value)::Union{Nothing, Int}
    value isa Integer || return nothing
    typemin(Int) <= value <= typemax(Int) || return nothing
    return Int(value)
end

function _normalize_string(value)::Union{Nothing, String}
    value isa AbstractString || return nothing
    return String(value)
end

function _normalize_status(value)::Union{Nothing, TodoStatus}
    value isa TodoStatus || return nothing
    return value
end

function _normalize_todo_frame(candidate::AbstractDataFrame)::Tuple{DataFrame, Vector{String}}
    missing_columns = [string(name) for name in TODO_COLUMNS if !(name in Symbol.(names(candidate)))]
    if !isempty(missing_columns)
        return _empty_todo_df(), [
            "Main.todo must contain columns id, parent, description, status. Missing: " *
            join(missing_columns, ", "),
        ]
    end

    ids = Int[]
    parents = TodoParent[]
    descriptions = String[]
    statuses = TodoStatus[]
    errors = String[]

    for row_index in 1:nrow(candidate)
        id_value = _normalize_int(candidate[row_index, :id])
        if isnothing(id_value)
            push!(errors, "Row $row_index has a non-integer id.")
            push!(ids, 0)
        else
            push!(ids, id_value)
        end

        parent_cell = candidate[row_index, :parent]
        if ismissing(parent_cell)
            push!(parents, missing)
        else
            parent_value = _normalize_int(parent_cell)
            if isnothing(parent_value)
                push!(errors, "Row $row_index has a non-integer parent.")
                push!(parents, missing)
            else
                push!(parents, parent_value)
            end
        end

        description_value = _normalize_string(candidate[row_index, :description])
        if isnothing(description_value)
            push!(errors, "Row $row_index has a non-string description.")
            push!(descriptions, "")
        else
            push!(descriptions, description_value)
        end

        status_value = _normalize_status(candidate[row_index, :status])
        if isnothing(status_value)
            push!(errors, "Row $row_index has an invalid status.")
            push!(statuses, pending)
        else
            push!(statuses, status_value)
        end
    end

    return DataFrame(
        id = ids,
        parent = parents,
        description = descriptions,
        status = statuses,
    ), unique(errors)
end

function _find_parent_cycle(
    ids_in_row_order::Vector{Int},
    parent_by_id::Dict{Int, TodoParent},
)::Union{Nothing, Vector{Int}}
    for id in ids_in_row_order
        seen = Dict{Int, Int}()
        chain = Int[]
        current = id
        while true
            if haskey(seen, current)
                return chain[seen[current]:end]
            end
            seen[current] = length(chain) + 1
            push!(chain, current)
            parent = get(parent_by_id, current, missing)
            ismissing(parent) && break
            haskey(parent_by_id, parent) || break
            current = parent
        end
    end
    return nothing
end

function _build_todo_tree(df::DataFrame)::TodoValidation
    errors = String[]
    row_by_id = Dict{Int, Int}()
    parent_by_id = Dict{Int, TodoParent}()
    children_by_parent = Dict{TodoParent, Vector{Int}}()
    active_ids = Int[]

    for row_index in 1:nrow(df)
        id = df[row_index, :id]
        parent = df[row_index, :parent]

        if haskey(row_by_id, id)
            push!(errors, "Duplicate todo id $id.")
        else
            row_by_id[id] = row_index
            parent_by_id[id] = parent
            push!(get!(children_by_parent, parent, Int[]), id)
        end

        df[row_index, :status] == in_progress && push!(active_ids, id)
    end

    for id in keys(row_by_id)
        parent = parent_by_id[id]
        if !ismissing(parent) && !haskey(row_by_id, parent)
            push!(errors, "Todo $id references missing parent $parent.")
        end
    end

    cycle = _find_parent_cycle(collect(df.id), parent_by_id)
    if !isnothing(cycle)
        push!(errors, "Parent cycle detected: $(join(cycle, " -> ")) -> $(first(cycle)).")
    end

    if length(active_ids) > 1
        push!(errors, "More than one in_progress row is present.")
    elseif length(active_ids) == 1
        active_id = only(active_ids)
        if !isempty(get(children_by_parent, active_id, Int[]))
            push!(errors, "Todo $active_id is in_progress but is not a leaf.")
        end
    end

    if !isempty(errors)
        return TodoValidation(nothing, unique(errors))
    end

    roots = copy(get(children_by_parent, missing, Int[]))
    leaves_in_row_order = Int[]
    for id in df.id
        isempty(get(children_by_parent, id, Int[])) && push!(leaves_in_row_order, id)
    end

    return TodoValidation(
        TodoTree(
            df,
            row_by_id,
            parent_by_id,
            children_by_parent,
            roots,
            leaves_in_row_order,
            active_ids,
        ),
        String[],
    )
end

function _validate_todo_frame(candidate::AbstractDataFrame)::TodoValidation
    df, errors = _normalize_todo_frame(candidate)
    !isempty(errors) && return TodoValidation(nothing, errors)
    return _build_todo_tree(df)
end

function _validate_todo(candidate)::TodoValidation
    candidate isa AbstractDataFrame || return TodoValidation(nothing, ["Main.todo must be a DataFrame."])
    return _validate_todo_frame(candidate)
end

function _require_valid_tree(candidate, prefix::String)::TodoTree
    validation = _validate_todo(candidate)
    isempty(validation.errors) || throw(ErrorException(_validation_message(prefix, validation.errors)))
    return validation.tree::TodoTree
end

function _current_todo_tree_for_mutation()::TodoTree
    session = _require_session()
    candidate = _main_todo_value()

    if candidate isa AbstractDataFrame
        tree = _require_valid_tree(candidate, "Main.todo is invalid.")
        session.todo_df = copy(tree.df)
        return tree
    end

    return _require_valid_tree(session.todo_df, "Session todo state is invalid.")
end

function _publish_todo!(df::DataFrame)::Nothing
    tree = _require_valid_tree(df, "Internal todo state is invalid.")
    session = _require_session()
    session.todo_df = copy(tree.df)
    Core.eval(Main, :(todo = $(copy(tree.df))))
    return nothing
end

function _subtree_end_row(tree::TodoTree, id::Int)::Int
    last_row = tree.row_by_id[id]
    for child_id in get(tree.children_by_parent, id, Int[])
        last_row = max(last_row, _subtree_end_row(tree, child_id))
    end
    return last_row
end

function _resolve_parent_id(
    tree::TodoTree,
    parent::TodoParent,
    after::TodoParent,
)::TodoParent
    if !ismissing(parent) && !haskey(tree.row_by_id, parent)
        throw(ErrorException("Todo parent $parent not found."))
    end

    if ismissing(after)
        return parent
    end

    haskey(tree.row_by_id, after) || throw(ErrorException("Todo id $after not found."))

    if ismissing(parent)
        return tree.parent_by_id[after]
    end

    if after == parent
        return parent
    end

    tree.parent_by_id[after] == parent ||
        throw(ErrorException("Cannot insert after todo $after under parent $parent."))
    return parent
end

function _insert_row_position(
    tree::TodoTree,
    parent::TodoParent,
    after::TodoParent,
)::Int
    if ismissing(after)
        if ismissing(parent)
            return nrow(tree.df) + 1
        end

        child_ids = get(tree.children_by_parent, parent, Int[])
        if isempty(child_ids)
            return tree.row_by_id[parent] + 1
        end
        return _subtree_end_row(tree, child_ids[end]) + 1
    end

    if !ismissing(parent) && after == parent
        return tree.row_by_id[parent] + 1
    end

    after_id = after::Int
    return _subtree_end_row(tree, after_id) + 1
end

function _active_id(tree::TodoTree)::Union{Nothing, Int}
    return length(tree.active_ids) == 1 ? only(tree.active_ids) : nothing
end

function _recompute_ancestor_chain!(df::DataFrame, tree::TodoTree, parent::TodoParent)::Nothing
    current_parent = parent
    while !ismissing(current_parent)
        child_ids = get(tree.children_by_parent, current_parent, Int[])
        all_done = all(df[tree.row_by_id[child_id], :status] == done for child_id in child_ids)
        df[tree.row_by_id[current_parent], :status] = all_done ? done : pending
        current_parent = tree.parent_by_id[current_parent]
    end
    return nothing
end

function _focus_leaf!(df::DataFrame, tree::TodoTree, id::Int)::Nothing
    haskey(tree.row_by_id, id) || throw(ErrorException("Todo id $id not found."))
    isempty(get(tree.children_by_parent, id, Int[])) ||
        throw(ErrorException("Cannot start todo $id: only leaf tasks can be in_progress."))

    row_index = tree.row_by_id[id]
    df[row_index, :status] == done &&
        throw(ErrorException("Cannot start todo $id: done tasks cannot be restarted."))

    for active_id in tree.active_ids
        haskey(tree.row_by_id, active_id) || continue
        df[tree.row_by_id[active_id], :status] = pending
    end

    df[row_index, :status] = in_progress
    _recompute_ancestor_chain!(df, tree, tree.parent_by_id[id])
    return nothing
end

function _first_pending_leaf(tree::TodoTree)::Union{Nothing, Int}
    for leaf_id in tree.leaves_in_row_order
        tree.df[tree.row_by_id[leaf_id], :status] == pending && return leaf_id
    end
    return nothing
end

function _next_pending_leaf(tree::TodoTree, after_id::Int)::Union{Nothing, Int}
    seen_after = false
    for leaf_id in tree.leaves_in_row_order
        if !seen_after
            seen_after = leaf_id == after_id
            continue
        end
        tree.df[tree.row_by_id[leaf_id], :status] == pending && return leaf_id
    end
    return nothing
end

function _path_to_root(tree::TodoTree, id::Int)::Vector{Int}
    path = Int[]
    current = id
    while true
        push!(path, current)
        parent = tree.parent_by_id[current]
        ismissing(parent) && break
        current = parent
    end
    reverse!(path)
    return path
end

function _subtree_has_pending(tree::TodoTree, id::Int)::Bool
    tree.df[tree.row_by_id[id], :status] == pending && return true
    for child_id in get(tree.children_by_parent, id, Int[])
        _subtree_has_pending(tree, child_id) && return true
    end
    return false
end

function _first_pending_sibling(tree::TodoTree, siblings::Vector{Int})::Union{Nothing, Int}
    for sibling_id in siblings
        _subtree_has_pending(tree, sibling_id) && return sibling_id
    end
    return nothing
end

function _next_pending_sibling(
    tree::TodoTree,
    siblings::Vector{Int},
    after_id::Int,
)::Union{Nothing, Int}
    seen_after = false
    for sibling_id in siblings
        if !seen_after
            seen_after = sibling_id == after_id
            continue
        end
        _subtree_has_pending(tree, sibling_id) && return sibling_id
    end
    return nothing
end

function _rendered_todo_label(
    tree::TodoTree,
    id::Int,
    active_id::Union{Nothing, Int},
)::String
    description = tree.df[tree.row_by_id[id], :description]
    return (!isnothing(active_id) && id == active_id) ? "$description [in progress]" : description
end

function _push_rendered_node!(
    lines::Vector{String},
    tree::TodoTree,
    id::Int,
    depth::Int,
    active_id::Union{Nothing, Int},
)::Nothing
    indent = repeat("  ", depth - 1)
    push!(lines, indent * "- " * _rendered_todo_label(tree, id, active_id))
    return nothing
end

function _render_focus_level!(
    lines::Vector{String},
    tree::TodoTree,
    siblings::Vector{Int},
    focus_path::Vector{Int},
    depth::Int,
    active_id::Union{Nothing, Int},
)::Nothing
    isempty(siblings) && return nothing

    focus_id = depth <= length(focus_path) ? focus_path[depth] : nothing
    if isnothing(focus_id) || !(focus_id in siblings)
        sibling_id = _first_pending_sibling(tree, siblings)
        isnothing(sibling_id) || _push_rendered_node!(lines, tree, sibling_id, depth, active_id)
        return nothing
    end

    _push_rendered_node!(lines, tree, focus_id, depth, active_id)

    child_ids = get(tree.children_by_parent, focus_id, Int[])
    if !isempty(child_ids)
        _render_focus_level!(lines, tree, child_ids, focus_path, depth + 1, active_id)
    end

    sibling_id = _next_pending_sibling(tree, siblings, focus_id)
    isnothing(sibling_id) || _push_rendered_node!(lines, tree, sibling_id, depth, active_id)
    return nothing
end

function _print_status_tree(tree::TodoTree)::Nothing
    df = tree.df
    n_done = count(==(done), df.status)
    n_in_progress = count(==(in_progress), df.status)
    n_pending = count(==(pending), df.status)

    println("[Tasks: $n_done done · $n_in_progress in progress · $n_pending pending]")

    if nrow(df) == 0
        println()
        println("No tasks yet.")
        return nothing
    end

    active_id = _active_id(tree)
    focus_leaf = isnothing(active_id) ? _first_pending_leaf(tree) : active_id
    if isnothing(focus_leaf)
        println()
        println("All tasks complete.")
        return nothing
    end

    println()
    println(isnothing(active_id) ? "Next path:" : "Current path:")
    lines = String[]
    _render_focus_level!(lines, tree, tree.roots, _path_to_root(tree, focus_leaf), 1, active_id)
    for line in lines
        println(line)
    end
    return nothing
end

"""
    todo_add!(description; parent=missing, after=missing, start=false) -> Int

Insert a new pending todo row and return its stable id.
"""
function todo_add!(
    description::String;
    parent::TodoParent = missing,
    after::TodoParent = missing,
    start::Bool = false,
)::Int
    tree = _current_todo_tree_for_mutation()
    parent_id = _resolve_parent_id(tree, parent, after)
    insert_at = _insert_row_position(tree, parent_id, after)
    next_id = isempty(tree.df.id) ? 1 : maximum(tree.df.id) + 1
    active_id = _active_id(tree)
    should_start = start || (!isnothing(active_id) && !ismissing(parent_id) && parent_id == active_id)

    if should_start
        for current_id in tree.active_ids
            haskey(tree.row_by_id, current_id) || continue
            tree.df[tree.row_by_id[current_id], :status] = pending
        end
    end

    insert!(
        tree.df,
        insert_at,
        (id = next_id, parent = parent_id, description = description, status = pending),
    )

    updated_tree = _require_valid_tree(tree.df, "Internal todo state is invalid.")
    _recompute_ancestor_chain!(tree.df, updated_tree, parent_id)

    if should_start
        updated_tree = _require_valid_tree(tree.df, "Internal todo state is invalid.")
        _focus_leaf!(tree.df, updated_tree, next_id)
    end

    _publish_todo!(tree.df)
    return next_id
end

"""
    todo_start!(id) -> Nothing

Make the given leaf task the sole `in_progress` item.
"""
function todo_start!(id::Int)::Nothing
    tree = _current_todo_tree_for_mutation()
    _focus_leaf!(tree.df, tree, id)
    _publish_todo!(tree.df)
    return nothing
end

"""
    todo_next!() -> Nothing

Mark the current `in_progress` leaf as done and advance to the next pending leaf.
Prints the updated status tree so the new active state is always visible.
"""
function todo_next!()::Nothing
    tree = _current_todo_tree_for_mutation()
    length(tree.active_ids) == 1 ||
        throw(ErrorException("todo_next! requires exactly one in_progress leaf."))

    current_id = only(tree.active_ids)
    tree.df[tree.row_by_id[current_id], :status] = done
    _recompute_ancestor_chain!(tree.df, tree, tree.parent_by_id[current_id])

    updated_tree = _require_valid_tree(tree.df, "Internal todo state is invalid.")
    next_id = _next_pending_leaf(updated_tree, current_id)
    if !isnothing(next_id)
        _focus_leaf!(tree.df, updated_tree, next_id)
    end

    _publish_todo!(tree.df)
    final_tree = _require_valid_tree(tree.df, "Internal todo state is invalid.")
    _print_status_tree(final_tree)
    return nothing
end

"""
    todo_refine_current!(descriptions::AbstractString...) -> Vector{Int}

Add multiple sibling child leaves under the current `in_progress` leaf in order.
The current leaf reverts to `pending` and the first new child becomes `in_progress`.
Returns the vector of new ids and prints the updated status tree.
"""
function todo_refine_current!(descriptions::AbstractString...)::Vector{Int}
    isempty(descriptions) &&
        throw(ArgumentError("todo_refine_current! requires at least one description"))

    tree = _current_todo_tree_for_mutation()
    length(tree.active_ids) == 1 ||
        throw(ErrorException("todo_refine_current! requires exactly one in_progress leaf."))

    parent = only(tree.active_ids)
    ids = Int[todo_add!(String(descriptions[1]); parent = parent)]
    for description in descriptions[2:end]
        push!(ids, todo_add!(String(description); after = last(ids)))
    end

    final_tree = _require_valid_tree(Main.todo, "Internal todo state is invalid.")
    _print_status_tree(final_tree)
    return ids
end

"""
    todo_delete!(id::Int) -> Nothing

Remove a pending leaf task by id, re-validate, and print the updated status tree.
Throws if `id` does not exist, is not a leaf, or has status `in_progress` or `done`.
"""
function todo_delete!(id::Int)::Nothing
    tree = _current_todo_tree_for_mutation()

    haskey(tree.row_by_id, id) || throw(ErrorException("Todo id $id not found."))
    isempty(get(tree.children_by_parent, id, Int[])) ||
        throw(ErrorException("Cannot delete todo $id: only leaf tasks can be deleted."))

    row_index = tree.row_by_id[id]
    status_val = tree.df[row_index, :status]
    status_val == in_progress &&
        throw(ErrorException("Cannot delete todo $id: in_progress tasks cannot be deleted."))
    status_val == done &&
        throw(ErrorException("Cannot delete todo $id: done tasks cannot be deleted."))

    deleteat!(tree.df, row_index)
    _publish_todo!(tree.df)
    final_tree = _require_valid_tree(tree.df, "Internal todo state is invalid.")
    _print_status_tree(final_tree)
    return nothing
end

"""
    status() -> Nothing

Validate and render the current todo state for `{{julia_state}}`.
"""
function status()::Nothing
    session = _session_ref[]
    if isnothing(session)
        return nothing
    end

    validation = _validate_todo(_main_todo_value())
    if !isempty(validation.errors)
        println("[Todo validation failed]")
        for error in validation.errors
            println("- $error")
        end
        if nrow(session.todo_df) > 0
            lkg_validation = _build_todo_tree(session.todo_df)
            if isnothing(lkg_validation.tree)
                return nothing
            end
            println()
            println("[Last known-good state:]")
            _print_status_tree(lkg_validation.tree::TodoTree)
        end
        return nothing
    end

    tree = validation.tree::TodoTree
    session.todo_df = copy(tree.df)
    _print_status_tree(tree)
    return nothing
end
