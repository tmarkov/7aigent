module CodeTree

using DataFrames
using DataFramesMeta
using Markdown
using SQLite
using SHA
using TreeSitter

include("types.jl")
include("config.jl")
include("config/cpp.jl")
include("config/julia.jl")
include("config/markdown.jl")
include("config/default.jl")
include("dataframes.jl")
include("discovery.jl")
include("parser.jl")
include("builder.jl")
include("summaries.jl")
include("symbols.jl")
include("cache.jl")
include("load.jl")
include("update_source.jl")

# Public API exports
export CodeTreeDB, load, reload, get_source, update_source, SourceText
export LanguageConfig, LanguageEntry, NodeMapping, DEFAULT_CONFIG, merge_config
export classify_node, language_for_file
export discover_files

end # module CodeTree
