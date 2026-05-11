# Domain newtypes — thin wrappers that make illegal states unrepresentable.
# The compiler prevents passing a NodeId where a FilePath is expected, etc.
#
# These types are used in function signatures and struct fields to enforce
# correct usage at compile time.  DataFrame columns store raw String/Int;
# conversion happens at the DataFrame boundary.

struct NodeId;     val::String; end
struct QName;      val::String; end
struct FilePath;   val::String; end
struct SymbolName; val::String; end
struct NodeKind;   val::String; end
struct LineNumber; val::Int;    end

# --- String conversions ---
Base.string(x::NodeId)     = x.val
Base.string(x::QName)      = x.val
Base.string(x::FilePath)   = x.val
Base.string(x::SymbolName) = x.val
Base.string(x::NodeKind)   = x.val
Base.string(x::LineNumber) = string(x.val)

Base.show(io::IO, x::NodeId)     = print(io, "NodeId(", repr(x.val), ")")
Base.show(io::IO, x::QName)      = print(io, "QName(", repr(x.val), ")")
Base.show(io::IO, x::FilePath)   = print(io, "FilePath(", repr(x.val), ")")
Base.show(io::IO, x::SymbolName) = print(io, "SymbolName(", repr(x.val), ")")
Base.show(io::IO, x::NodeKind)   = print(io, "NodeKind(", repr(x.val), ")")
Base.show(io::IO, x::LineNumber) = print(io, "LineNumber(", x.val, ")")

# --- Equality, hashing, comparison ---
Base.:(==)(a::NodeId, b::NodeId)         = a.val == b.val
Base.:(==)(a::QName, b::QName)           = a.val == b.val
Base.:(==)(a::FilePath, b::FilePath)     = a.val == b.val
Base.:(==)(a::SymbolName, b::SymbolName) = a.val == b.val
Base.:(==)(a::NodeKind, b::NodeKind)     = a.val == b.val
Base.:(==)(a::LineNumber, b::LineNumber) = a.val == b.val

Base.hash(x::NodeId, h::UInt)     = hash(x.val, h)
Base.hash(x::QName, h::UInt)      = hash(x.val, h)
Base.hash(x::FilePath, h::UInt)   = hash(x.val, h)
Base.hash(x::SymbolName, h::UInt) = hash(x.val, h)
Base.hash(x::NodeKind, h::UInt)   = hash(x.val, h)
Base.hash(x::LineNumber, h::UInt) = hash(x.val, h)

Base.isless(a::LineNumber, b::LineNumber) = a.val < b.val

# --- String operations used in id/qname construction ---
Base.isempty(x::QName)     = isempty(x.val)
Base.isempty(x::NodeId)    = isempty(x.val)
Base.isempty(x::FilePath)  = isempty(x.val)

# --- Conversion helpers for DataFrame boundary ---
"""Unwrap a domain type to its raw value, passing `missing` through."""
_raw(x::NodeId)     = x.val
_raw(x::QName)      = x.val
_raw(x::FilePath)   = x.val
_raw(x::SymbolName) = x.val
_raw(x::NodeKind)   = x.val
_raw(x::LineNumber) = x.val
_raw(::Missing)     = missing
_raw(x)             = x  # passthrough for values already raw

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