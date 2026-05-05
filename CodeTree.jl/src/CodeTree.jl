module CodeTree

using DataFrames
using DataFramesMeta
using SQLite
using SHA
using TreeSitter
using tree_sitter_cpp_jll
using tree_sitter_julia_jll

include("types.jl")
include("config.jl")
include("dataframes.jl")
include("discovery.jl")
include("parser.jl")
include("summaries.jl")
include("builder.jl")
include("cache.jl")
include("load.jl")
include("update_source.jl")

# Public API exports
export CodeTreeDB, load, reload, update_source
export LanguageConfig, LanguageEntry, NodeMapping, classify_node, language_for_file
export discover_files

end # module CodeTree
