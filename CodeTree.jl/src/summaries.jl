# Summary extraction — stub; fully implemented in Phase 5.
#
# _extract_summary is called during tree-building (builder.jl) for every span
# that has a summary_src. _readme_summary is called from load.jl for directory
# and codebase nodes.  Both return missing until Phase 5.

_extract_summary(
    src::Union{String,Nothing},
    language::Union{String,Missing},
)::Union{String,Missing} = missing

_readme_summary(path::String)::Union{String,Missing} = missing
