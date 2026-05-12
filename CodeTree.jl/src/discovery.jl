# File discovery — implemented in Phase 3

struct GitIgnoreRule
    base_dir::String
    regex::Regex
    negated::Bool
    dir_only::Bool
    basename_only::Bool
end

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

    # Fallback: walk the directory tree manually while still honouring nested
    # .gitignore files and pruning obviously non-source metadata trees.
    results = String[]
    rules_by_dir = Dict{String,Vector{GitIgnoreRule}}("" => GitIgnoreRule[])
    for (dir, subdirs, files) in walkdir(abs_root)
        rel_dir = _normalize_rel_path(relpath(dir, abs_root))
        active_rules = get!(rules_by_dir, rel_dir) do
            parent_dir = isempty(rel_dir) ? "" : _normalize_rel_path(dirname(rel_dir))
            copy(get(rules_by_dir, parent_dir, GitIgnoreRule[]))
        end
        append!(active_rules, _parse_gitignore_file(joinpath(dir, ".gitignore"), rel_dir))

        filter!(subdirs) do subdir
            !_always_excluded_dir(subdir) &&
            !_is_ignored(_join_rel_path(rel_dir, subdir), true, active_rules)
        end

        for f in files
            rel_path = _join_rel_path(rel_dir, f)
            if _is_ignored(rel_path, false, active_rules) ||
               _is_binary_file(joinpath(dir, f))
                continue
            end
            push!(results, rel_path)
        end

        for subdir in subdirs
            rules_by_dir[_join_rel_path(rel_dir, subdir)] = copy(active_rules)
        end
    end
    return results
end

function _always_excluded_dir(name::String)::Bool
    return name in (".7aigent", ".git", ".hg", ".svn")
end

function _join_rel_path(parent::String, child::String)::String
    return isempty(parent) ? child : _normalize_rel_path(joinpath(parent, child))
end

function _normalize_rel_path(path::String)::String
    normalized = replace(normpath(path), '\\' => '/')
    return normalized == "." ? "" : normalized
end

function _parse_gitignore_file(path::String, base_dir::String)::Vector{GitIgnoreRule}
    isfile(path) || return GitIgnoreRule[]

    rules = GitIgnoreRule[]
    for raw_line in eachline(path)
        rule = _parse_gitignore_line(raw_line, base_dir)
        isnothing(rule) || push!(rules, rule)
    end
    return rules
end

function _parse_gitignore_line(raw_line::String, base_dir::String)::Union{GitIgnoreRule,Nothing}
    line = chomp(raw_line)
    isempty(line) && return nothing

    if startswith(line, "\\#") || startswith(line, "\\!")
        line = line[2:end]
    elseif startswith(line, "#")
        return nothing
    end

    negated = startswith(line, "!")
    negated && (line = line[2:end])
    isempty(line) && return nothing

    dir_only = endswith(line, "/")
    dir_only && (line = line[1:end-1])
    isempty(line) && return nothing

    anchored = startswith(line, "/")
    anchored && (line = line[2:end])
    isempty(line) && return nothing

    basename_only = !anchored && !occursin('/', line)
    regex = basename_only ? _gitignore_basename_regex(line) : _gitignore_path_regex(line)
    return GitIgnoreRule(base_dir, regex, negated, dir_only, basename_only)
end

function _gitignore_basename_regex(pattern::AbstractString)::Regex
    io = IOBuffer()
    print(io, '^')
    i = firstindex(pattern)
    while i <= lastindex(pattern)
        c = pattern[i]
        if c == '*'
            next_i = nextind(pattern, i)
            if next_i <= lastindex(pattern) && pattern[next_i] == '*'
                print(io, ".*")
                i = nextind(pattern, next_i)
            else
                print(io, ".*")
                i = next_i
            end
        elseif c == '?'
            print(io, '.')
            i = nextind(pattern, i)
        else
            _append_regex_literal!(io, c)
            i = nextind(pattern, i)
        end
    end
    print(io, '$')
    return Regex(String(take!(io)))
end

function _gitignore_path_regex(pattern::AbstractString)::Regex
    io = IOBuffer()
    print(io, '^')
    i = firstindex(pattern)
    while i <= lastindex(pattern)
        if _starts_with(pattern, i, "**/")
            print(io, "(?:[^/]+/)*")
            i = nextind(pattern, i, 3)
            continue
        elseif _starts_with(pattern, i, "**")
            print(io, ".*")
            i = nextind(pattern, i, 2)
            continue
        end

        c = pattern[i]
        if c == '*'
            print(io, "[^/]*")
        elseif c == '?'
            print(io, "[^/]")
        else
            _append_regex_literal!(io, c)
        end
        i = nextind(pattern, i)
    end
    print(io, '$')
    return Regex(String(take!(io)))
end

function _append_regex_literal!(io::IOBuffer, c::Char)::Nothing
    if c in ('\\', '.', '^', '$', '+', '(', ')', '[', ']', '{', '}', '|')
        print(io, '\\')
    end
    print(io, c)
    return nothing
end

function _starts_with(pattern::AbstractString, i::Int, needle::AbstractString)::Bool
    ncodeunits(pattern) - i + 1 < ncodeunits(needle) && return false
    return SubString(pattern, i, nextind(pattern, i, ncodeunits(needle)) - 1) == needle
end

function _candidate_from_base(base_dir::String, rel_path::String)::Union{String,Nothing}
    if isempty(base_dir)
        return rel_path
    elseif rel_path == base_dir
        return ""
    elseif startswith(rel_path, base_dir * "/")
        return rel_path[length(base_dir) + 2:end]
    end
    return nothing
end

function _rule_match(rule::GitIgnoreRule, rel_path::String, is_dir::Bool)::Union{Bool,Nothing}
    candidate = _candidate_from_base(rule.base_dir, rel_path)
    isnothing(candidate) && return nothing

    target = rule.basename_only ? basename(candidate) : candidate
    occursin(rule.regex, target) || return nothing
    rule.dir_only && !is_dir && return nothing
    return !rule.negated
end

function _is_ignored(rel_path::String, is_dir::Bool, rules::Vector{GitIgnoreRule})::Bool
    ignored = false
    for rule in rules
        matched = _rule_match(rule, rel_path, is_dir)
        isnothing(matched) || (ignored = matched)
    end
    return ignored
end

function _is_binary_file(path::String)::Bool
    isfile(path) || return false
    open(path, "r") do io
        n = min(filesize(path), 8192)
        n == 0 && return false
        return any(==(0x00), read(io, n))
    end
end
