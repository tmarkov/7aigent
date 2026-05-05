# API Reference

Complete reference for the public API of the test codebase.
See [overview.md](overview.md) for architecture context.

---

## C++ API (`src/algorithms.hpp`)

### `quick_sort`

```cpp
void quick_sort(int *arr, int n);
```

In-place quicksort. Average O(n log n). Calls `swap` internally.

### `merge_sort`

```cpp
void merge_sort(int *arr, int n);
```

In-place stable merge sort. Allocates a temporary buffer via `malloc`.

### `timed_sort`

```cpp
SortResult timed_sort(int *arr, int n);
```

Runs `quick_sort` and returns a `SortResult` with `elapsed_ms`.

### `process` (overloaded)

```cpp
void process(int *arr, int n);     // delegates to quick_sort
void process(double *arr, int n);  // truncates then delegates
```

Two overloads of `process` — tests R1 (duplicate sibling names).

---

## Julia API (`julia/core.jl`)

### `sort_array`

```julia
sort_array(v::Vector{Int})     -> Vector{Int}
sort_array(v::Vector{Float64}) -> Vector{Float64}
```

Two methods of `sort_array` — tests R1 for Julia (duplicate sibling names).
The `Int` version calls `_quicksort!`; the `Float64` version calls `sort`.

### `compute_stats`

```julia
compute_stats(v::AbstractVector) -> DataStats
```

Returns a `DataStats` struct. Calls `find_median` and `clamp_value` internally.

### `search_sorted`

```julia
search_sorted(arr::Vector{Int}, target::Int) -> Int
```

Binary search. Returns 1-based index or `-1`.

---

## Untagged example (R21a intersection test)

The block below has no language tag. Tokens are intersected with known names.
`DataStats` and `compute_stats` must appear in db.symbols; `MyUnknownType` must not.

```
result = compute_stats(data)
s = DataStats(n, min_val, max_val, median)
x = MyUnknownType()
```

Inline: `DataStats`, `SortResult`, `clamp_value`, and `elapsed_ms` are
known symbols. `elapsed` (without `_ms`) is plain prose and must not match.
