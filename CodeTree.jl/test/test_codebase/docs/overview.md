# Architecture Overview

This document describes the two-layer architecture of the test codebase.
See also [api.md](api.md) and the [README](../README.md).

## Layers

1. **C++ layer** (`src/`) — low-level sorting routines with no dependencies.
2. **Julia layer** (`julia/`) — high-level wrapper, statistics, and I/O.

The Julia layer calls into the C++ layer via `ccall` in a production build;
in this test codebase the Julia functions are pure-Julia stand-ins.

## Data Flow

```
User input  →  sort_array / compute_stats  →  DataStats
                    ↓
              _quicksort! / find_median
                    ↓
              clamp_value / is_sorted   (Utils)
```

Untagged diagram above — none of the words are code symbols, so the
intersection with db.code names should yield only the explicitly named
functions: `sort_array`, `compute_stats`, `_quicksort!`, `find_median`,
`clamp_value`, `is_sorted`.

## Error Handling

Both layers follow a fail-fast policy:

- C++ functions print to `stderr` and return early on invalid input.
- Julia functions `throw` on invalid input (see `compute_stats`, `find_median`).

## Threading

Not thread-safe. `MAX_N` is a global constant read by `bucket_sort`; no
locking is required because it is never written after initialisation.
