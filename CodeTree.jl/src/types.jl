# Domain newtypes — thin wrappers that make illegal states unrepresentable.
# The compiler prevents passing a NodeId where a FilePath is expected, etc.

struct NodeId;    val::String; end
struct QName;     val::String; end
struct FilePath;  val::String; end
struct SymbolName; val::String; end
struct NodeKind;  val::String; end
struct LineNumber; val::Int;   end

Base.string(x::NodeId)    = x.val
Base.string(x::QName)     = x.val
Base.string(x::FilePath)  = x.val
Base.string(x::SymbolName) = x.val
Base.string(x::NodeKind)  = x.val
Base.string(x::LineNumber) = string(x.val)

"""
    assign_ordinal_ids(names, line_starts) -> Vector{String}

Given sibling node names and their line_start positions, return id/qname
suffixes with ordinal disambiguation for duplicates. The first occurrence
keeps its base name; the second gets `\$2`, the third `\$3`, etc., ordered
by ascending line_start (R1).
"""
function assign_ordinal_ids(names::Vector{String},
                            line_starts::Vector{<:Union{Int,Missing}})::Vector{String}
    order = sortperm(coalesce.(line_starts, 0))
    result = Vector{String}(undef, length(names))
    counts = Dict{String,Int}()
    for i in order
        name = names[i]
        n = get(counts, name, 0) + 1
        counts[name] = n
        result[i] = n == 1 ? name : "$(name)\$$(n)"
    end
    return result
end