module CodeTree

# Phase 0 skeleton — source files added incrementally in later phases.

"""Stub: full implementation added in later phases."""
struct CodeTreeDB end

load(root_path::AbstractString, config; kwargs...) =
    error("load not yet implemented")
reload(db::CodeTreeDB) = error("reload not yet implemented")
update_source(db::CodeTreeDB, id, new_source) =
    error("update_source not yet implemented")

export CodeTreeDB, load, reload, update_source

end # module CodeTree
