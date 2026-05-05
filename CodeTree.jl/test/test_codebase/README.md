# Test Codebase

A minimal codebase used to test [CodeTree.jl](../CodeTree.jl/README.md).

## Structure

- `src/` — C++ sorting algorithms and a driver class
- `julia/` — Julia high-level wrapper (DataProcessor module)
- `docs/` — Additional documentation
- `data/` — Configuration (unknown language → tests R8)

See [docs/overview.md](docs/overview.md) for architecture notes and
[docs/api.md](docs/api.md) for the API reference.

## Quick Start

Sort an array in C++:

```cpp
int arr[] = {5, 3, 1, 4, 2};
quick_sort(arr, 5);
SortResult r = timed_sort(arr, 5);
```

Sort an array in Julia:

```julia
using DataProcessor
sorted = sort_array([5, 3, 1, 4, 2])
stats  = compute_stats([5, 3, 1, 4, 2])
```

Untagged block — tokens are intersected with known names (R21a, second rule).
`unknown_algorithm` below is NOT a known symbol and must not appear in db.symbols.
`quick_sort` and `sort_array` ARE known and must appear.

```
quick_sort(arr, n)
sort_array(v)
unknown_algorithm(x)
```

## Key Symbols

Inline backtick references (R21a, third rule):
`quick_sort`, `merge_sort`, `bucket_sort`, `sort_array`, `compute_stats`,
`DataStats`, `MAX_N`, `SortResult`.

Plain prose words like "algorithm" and "result" must **not** appear in db.symbols
even though they appear inside backtick spans in this sentence.
