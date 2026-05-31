# #0021 — Codebase root node gets empty id and name

## Summary

When `CodeTree.load(".")` is called, the codebase root node ends up with
`id=""` and `name=""`. This makes the root indistinguishable from "missing"
at a glance, and causes all top-level children to show `parent=""` which
looks like they have no parent.

## Root cause

`load.jl:22-23`:

```julia
root_path     = abspath(root_path)
codebase_name = basename(root_path)
```

Julia's `abspath(".")` returns a path with a trailing slash (e.g.
`"/home/user/project/"`). Then `basename("/home/user/project/")` returns
`""` because the component after the trailing slash is empty.

Line 51 then uses this empty string as the node id:

```julia
codebase_id = NodeId(codebase_name)
```

## Expected behavior

The root node should have a meaningful id and name derived from the
directory name (e.g. `"7aigent"` for a repo at `/home/user/dev/7aigent`).

## Fix

Strip trailing path separators before calling `basename`:

```julia
codebase_name = basename(rstrip(root_path, '/'))
```

Or use `splitpath`:

```julia
codebase_name = splitpath(root_path)[end]
```

## Location

`CodeTree.jl/src/load.jl:22-23, 51`
