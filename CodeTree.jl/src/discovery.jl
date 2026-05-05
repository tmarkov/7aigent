# File discovery — implemented in Phase 3

"""
    discover_files(root::AbstractString) -> Vector{String}

Return all source file paths under `root` that should be indexed, as
relative paths from `root`.

When `root` is inside a git repository, uses `git ls-files --cached
--others --exclude-standard` to enumerate tracked files and untracked
files not excluded by `.gitignore` (R5). Falls back to `walkdir` when git
is unavailable or the directory is not inside a git repo.

The `.7aigent/` directory is always excluded regardless of `.gitignore`.
"""
function discover_files(root::AbstractString)::Vector{String}
    abs_root = abspath(root)

    # Try git first (R5): honours .gitignore and includes untracked files.
    git_result = try
        out = readchomp(`git -C $abs_root ls-files --cached --others --exclude-standard`)
        isempty(out) ? String[] : split(out, '\n')
    catch
        nothing
    end

    if !isnothing(git_result)
        # Filter out .7aigent/ subtree (cache dir, never indexed).
        return filter(p -> !startswith(p, ".7aigent/") && p != ".7aigent", git_result)
    end

    # Fallback: walk the directory tree manually.
    results = String[]
    for (dir, subdirs, files) in walkdir(abs_root)
        # Prune .7aigent from traversal in-place.
        filter!(d -> d != ".7aigent", subdirs)
        rel_dir = relpath(dir, abs_root)
        for f in files
            rel_path = rel_dir == "." ? f : joinpath(rel_dir, f)
            push!(results, rel_path)
        end
    end
    return results
end
