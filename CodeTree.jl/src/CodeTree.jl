module CodeTree

using DataFrames
using DataFramesMeta
using SHA

include("types.jl")
include("dataframes.jl")

# Stubs for phases 3+.
load(root_path::AbstractString, config; kwargs...) =
    error("load not yet implemented")
reload(db::CodeTreeDB) = error("reload not yet implemented")
update_source(db::CodeTreeDB, id, new_source) =
    error("update_source not yet implemented")

# Public API exports
export CodeTreeDB, load, reload, update_source

end # module CodeTree
