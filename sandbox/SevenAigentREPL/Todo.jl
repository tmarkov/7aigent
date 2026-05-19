# Todo.jl — Task tracking for the agent session

"""
Represents the lifecycle status of a todo item.
"""
@enum TodoStatus pending in_progress done

"""
    todo_add!(description) -> Int

Append a new `pending` item to `Main.todo` and return its id.
The id is `max(existing ids) + 1`, or `1` if the table is empty.
"""
function todo_add!(description::String)::Int
    df = Main.todo::DataFrame
    next_id = isempty(df.id) ? 1 : maximum(df.id) + 1
    push!(df, (id = next_id, description = description, status = pending))
    return next_id
end

"""
    todo_start!(id) -> Nothing

Mark the item with the given `id` as `in_progress`.
Throws `ErrorException` if another item is already `in_progress`, or if `id`
is not found.
"""
function todo_start!(id::Int)::Nothing
    df = Main.todo::DataFrame
    idx = findfirst(==(id), df.id)
    isnothing(idx) && throw(ErrorException("Todo id $id not found."))
    conflict = findfirst(==(in_progress), df.status)
    if !isnothing(conflict) && df[conflict, :id] != id
        name = df[conflict, :description]
        throw(ErrorException("Cannot start todo $id: item $(df[conflict,:id]) (\"$name\") is already in progress."))
    end
    df[idx, :status] = in_progress
    return nothing
end

"""
    todo_done!(id) -> Nothing

Mark the item with the given `id` as `done`.
Throws `ErrorException` if `id` is not found.
"""
function todo_done!(id::Int)::Nothing
    df = Main.todo::DataFrame
    idx = findfirst(==(id), df.id)
    isnothing(idx) && throw(ErrorException("Todo id $id not found."))
    df[idx, :status] = done
    return nothing
end

"""
    status() -> Nothing

Print a brief summary of the current todo state to stdout.
Never throws; no-ops silently if `Main.todo` is not a valid DataFrame.
"""
function status()::Nothing
    if !isdefined(Main, :todo) || !(Main.todo isa DataFrame)
        return nothing
    end
    df = Main.todo
    n_done       = count(==(done),        df.status)
    n_in_progress = count(==(in_progress), df.status)
    n_pending    = count(==(pending),     df.status)
    println("[Tasks: $n_done done · $n_in_progress in progress · $n_pending pending]")
    for row in eachrow(df)
        row.status == in_progress && println("→ In progress: \"$(row.description)\"")
    end
    for row in eachrow(df)
        if row.status == pending
            println("→ Next: \"$(row.description)\"")
            break
        end
    end
    return nothing
end
