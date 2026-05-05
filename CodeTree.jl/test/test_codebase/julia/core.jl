"""
    module DataProcessor

High-level sorting, searching, and statistics utilities.

Wraps low-level algorithms with a Julia-friendly interface including
support for custom comparators and structured result types.
R19: this module-level docstring provides the module's summary.
"""
module DataProcessor

# R9a (definition patterns): `using` and `import` produce kind=import rows.
using Statistics   # standard library — median, mean
import Base: show  # selective import

include("utils.jl")
using .Utils: clamp_value, format_result, is_sorted

export sort_array, find_median, search_sorted, compute_stats, DataStats


# -------------------------------------------------------------------------
# Types
# -------------------------------------------------------------------------

"""
    DataStats

Summary statistics for a numeric dataset.

Fields: `n` (count), `min_val`, `max_val`, `median`.
"""
struct DataStats
    n::Int
    min_val::Float64
    max_val::Float64
    median::Float64
end

# Custom display for DataStats — short, no docstring (R20: missing summary).
function Base.show(io::IO, s::DataStats)
    print(io, "DataStats(n=$(s.n), min=$(s.min_val), " *
              "max=$(s.max_val), median=$(s.median))")
end


# -------------------------------------------------------------------------
# Sorting — multiple dispatch (R1: duplicate sibling names)
# -------------------------------------------------------------------------

"""
    sort_array(v::Vector{Int}) -> Vector{Int}

Sort a vector of integers using an in-place quicksort.
Returns a new sorted vector; the input is not modified.
"""
function sort_array(v::Vector{Int})
    result = copy(v)
    _quicksort!(result, 1, length(result))
    return result
end

"""
    sort_array(v::Vector{Float64}) -> Vector{Float64}

Sort a vector of floats using Julia's built-in sort (Timsort, stable).
R1: second sibling named `sort_array`; gets id/qname suffix `sort_array\$2`.
"""
function sort_array(v::Vector{Float64})
    # Delegates to Base.sort for stability guarantees.
    return sort(v)
end

# Internal quicksort helper — short function, tests R11 (detail suppressed).
# This function spans ~20 lines, well under detail_threshold=30.
function _quicksort!(arr, lo, hi)
    if lo >= hi
        return
    end
    pivot = arr[(lo + hi) ÷ 2]
    i, j = lo, hi
    while i <= j
        while arr[i] < pivot; i += 1; end
        while arr[j] > pivot; j -= 1; end
        if i <= j
            arr[i], arr[j] = arr[j], arr[i]
            i += 1
            j -= 1
        end
    end
    _quicksort!(arr, lo, j)
    _quicksort!(arr, i, hi)
end


# -------------------------------------------------------------------------
# Searching
# -------------------------------------------------------------------------

# Binary search on a sorted vector.
# Returns the 1-based index of `target`, or -1 if not found.
# R18: this comment block is absorbed into search_sorted's span (R14b).
function search_sorted(arr::Vector{Int}, target::Int)
    lo, hi = 1, length(arr)
    while lo <= hi
        mid = (lo + hi) ÷ 2
        if arr[mid] == target
            return mid
        elseif arr[mid] < target
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return -1
end


# -------------------------------------------------------------------------
# Statistics — long function tests R11 (detail nodes shown)
# -------------------------------------------------------------------------

"""
    find_median(v::AbstractVector) -> Float64

Compute the median of a numeric vector. Sorts a copy internally.
Handles both even- and odd-length inputs.
"""
function find_median(v::AbstractVector)
    if isempty(v)
        throw(ArgumentError("cannot compute median of empty vector"))
    end
    sorted = sort(collect(Float64, v))
    n = length(sorted)
    if isodd(n)
        return sorted[(n + 1) ÷ 2]
    else
        return (sorted[n ÷ 2] + sorted[n ÷ 2 + 1]) / 2.0
    end
end

"""
    compute_stats(v::AbstractVector) -> DataStats

Compute summary statistics (min, max, median) for a dataset.

This function is intentionally long (> detail_threshold = 30 lines) so that
inner loops and conditionals produce detail rows in db.code, exercising R11.
Contrast with `_quicksort!` above, which is short and suppresses detail rows.
"""
function compute_stats(v::AbstractVector)
    n = length(v)
    if n == 0
        throw(ArgumentError("compute_stats: empty input"))
    end

    # Convert to Float64 for uniform arithmetic.
    data = collect(Float64, v)

    # Find min and max in a single pass.
    min_val = data[1]
    max_val = data[1]
    for x in data
        if x < min_val
            min_val = x
        end
        if x > max_val
            max_val = x
        end
    end

    # Validate range before proceeding.
    if !isfinite(min_val) || !isfinite(max_val)
        throw(ArgumentError("compute_stats: non-finite values in input"))
    end

    # Clamp values to a representable range (calls Utils.clamp_value).
    clamped = [clamp_value(x, -1e15, 1e15) for x in data]

    # Compute median on the clamped data.
    med = find_median(clamped)

    # Build and return the result, catching unexpected errors.
    try
        result = DataStats(n, min_val, max_val, med)
        return result
    catch e
        @error "compute_stats: failed to construct DataStats" exception = e
        rethrow(e)
    end
end


# -------------------------------------------------------------------------
# R14a: else-if chain to test shared-line boundary
# -------------------------------------------------------------------------

# Classify a value into one of three buckets.
# The `elseif` lines test R14a: `else` shares a line with the closing `end`
# of the preceding branch in some formatters; here we test the canonical form.
function classify(x::Float64)
    if x < 0.0
        return :negative
    elseif x == 0.0
        return :zero
    else
        return :positive
    end
end


# -------------------------------------------------------------------------
# kind=with: do-block (R10 — landmark node; R9 — config maps do_clause)
# -------------------------------------------------------------------------

"""
    write_stats(stats::DataStats, path::String)

Write a DataStats summary to a file. Uses a `do`-block (`open ... do io`),
which the language config maps to `kind=with`. Tests R9/R10 for the `with`
node kind in Julia.
"""
function write_stats(stats::DataStats, path::String)
    open(path, "w") do io
        write(io, format_result("n",      stats.n)       * "\n")
        write(io, format_result("min",    stats.min_val) * "\n")
        write(io, format_result("max",    stats.max_val) * "\n")
        write(io, format_result("median", stats.median)  * "\n")
    end
end


# -------------------------------------------------------------------------
# R14b negative case: comment separated from function by a blank line
# -------------------------------------------------------------------------

# This comment block is followed by a blank line before the declaration.
# Per R14b it is NOT absorbed into noop's span; noop has no documentation
# and its summary is `missing` (tests R20).

function noop(x)
    return x
end

end  # module DataProcessor
