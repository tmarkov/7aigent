module CodeTree

using DataFrames
using DataFramesMeta
using SHA

include("types.jl")
include("config.jl")
include("dataframes.jl")
include("discovery.jl")

# Stubs for phases 4+.
load(root_path::AbstractString, config::LanguageConfig; kwargs...) =
    error("load not yet implemented")
reload(db::CodeTreeDB) = error("reload not yet implemented")
update_source(db::CodeTreeDB, id, new_source) =
    error("update_source not yet implemented")

# Public API exports
export CodeTreeDB, load, reload, update_source
export LanguageConfig, LanguageEntry, NodeMapping, classify_node, language_for_file
export discover_files

end # module CodeTree
