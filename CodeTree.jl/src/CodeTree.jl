module CodeTree

using DataFrames
using DataFramesMeta
using Markdown
using SQLite
using SHA
using TreeSitter

function _is_git_command_failure(e::Exception)::Bool
    return e isa ProcessFailedException || e isa Base.IOError
end

function _is_file_read_failure(e::Exception)::Bool
    return e isa SystemError
end

function _is_query_compile_failure(e::Exception)::Bool
    return e isa TreeSitter.QueryException
end

function _is_dataframe_selector_failure(e::Exception)::Bool
    return e isa ArgumentError || e isa BoundsError || e isa KeyError
end

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
include("git.jl")

# Public API exports
export CodeTreeDB, load, reload, get_source, update_source!
export git_file_status, git_diff
export LanguageConfig, LanguageEntry, NodeMapping, DEFAULT_CONFIG, merge_config
export classify_node, language_for_file
export discover_files

end # module CodeTree
