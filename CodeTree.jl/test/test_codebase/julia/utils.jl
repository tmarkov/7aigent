"""
    module Utils

Utility helpers for DataProcessor.

Provides clamping, formatting, and validation functions used across the
package. All functions are pure (no side effects).
R19: module-level docstring provides the summary.
"""
module Utils

export clamp_value, format_result, is_sorted


# -------------------------------------------------------------------------
# Value helpers
# -------------------------------------------------------------------------

"""
    clamp_value(x, lo, hi)

Return `x` clamped to the closed interval `[lo, hi]`.
"""
function clamp_value(x, lo, hi)
    if x < lo
        return lo
    elseif x > hi
        return hi
    else
        return x
    end
end

"""
    format_result(label::String, value) -> String

Format a label-value pair as a human-readable string, e.g. `"n: 42"`.
"""
function format_result(label::String, value)
    return "$label: $value"
end


# -------------------------------------------------------------------------
# Array predicates
# -------------------------------------------------------------------------

# Check whether an array is sorted in non-decreasing order.
# R18: comment block immediately before is_sorted — absorbed into its span.
function is_sorted(arr::AbstractVector)
    for i in 2:length(arr)
        if arr[i] < arr[i-1]
            return false
        end
    end
    return true
end

# R16: sibling_order test — two short functions with no blank line between
# them, verifying order is determined by line_start, not declaration order.
function first_element(arr::AbstractVector)
    isempty(arr) && throw(ArgumentError("empty array"))
    return arr[1]
end
function last_element(arr::AbstractVector)
    isempty(arr) && throw(ArgumentError("empty array"))
    return arr[end]
end


# -------------------------------------------------------------------------
# Intentionally undocumented — tests R20 (missing summary)
# -------------------------------------------------------------------------

function _square_plus_one(x::Int)
    return x * x + 1
end

# R1 duplicate-name test within Utils: two methods named `_parse`.
# First sibling keeps base id; second becomes `_parse$2`.
function _parse(s::String)
    return parse(Int, s)
end

function _parse(s::String, base::Int)
    return parse(Int, s; base = base)
end

end  # module Utils
