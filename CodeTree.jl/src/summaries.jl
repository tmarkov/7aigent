# Summary extraction (R17–R20a).
#
# _extract_summary is called during tree-building (builder.jl) for every span
# that has a summary_src.  Directory/codebase summaries from README files are
# handled separately in load.jl.

"""
    _extract_summary(src) -> Union{String, Missing}

Extract a human-readable one-to-three-line summary from `src`, which may be:
  - A Julia triple-quoted docstring `\"\"\"…\"\"\"`
  - A block of `//` or `/* */` C++ comment lines
  - The raw text of a standalone comment node (kind=comment, R20a)

Returns `missing` when `src` is `nothing` or all-blank after stripping.
"""
function _extract_summary(src::Union{String,Nothing})::Union{String,Missing}
    isnothing(src) && return missing
    lines = split(src, '\n')

    # Strip Julia triple-quote delimiters.
    if any(l -> startswith(strip(l), "\"\"\""), lines)
        lines = filter(l -> !startswith(strip(l), "\"\"\""), lines)
    end

    # Strip C++/Julia line-comment prefixes (// and leading * from /* */).
    cleaned = String[]
    for raw in lines
        s = strip(raw)
        if startswith(s, "//")
            s = strip(s[3:end])
        elseif startswith(s, "/*") && endswith(s, "*/")
            s = strip(s[3:end-2])
        elseif startswith(s, "/*")
            s = strip(s[3:end])
        elseif startswith(s, "*/")
            s = strip(s[3:end])
        elseif startswith(s, "*")
            s = strip(s[2:end])
        end
        push!(cleaned, s)
    end

    # Remove leading/trailing blank lines, collapse internal blanks,
    # and take at most three non-blank lines.
    non_blank = filter(!isempty, cleaned)
    isempty(non_blank) && return missing

    # Skip lines that are purely a function/method signature header
    # (e.g. `    sort_array(v) -> Vector{Int}` right after `"""`).
    summary_lines = String[]
    for ln in non_blank
        # Skip the leading "    FunctionName(args)" signature line in Julia docstrings.
        isempty(summary_lines) && startswith(ln, r"[A-Za-z_]") &&
            occursin(r"\(", ln) && length(summary_lines) == 0 && continue
        push!(summary_lines, ln)
        length(summary_lines) == 3 && break
    end

    isempty(summary_lines) && return missing
    return join(summary_lines, ' ')
end

"""
    _readme_summary(readme_path) -> Union{String, Missing}

Extract the first non-blank, non-heading paragraph from a Markdown README file.
Used for codebase-root and directory-module summaries (R19).
"""
function _readme_summary(readme_path::String)::Union{String,Missing}
    isfile(readme_path) || return missing
    content = read(readme_path, String)
    lines = split(content, '\n')

    paragraph = String[]
    in_para = false
    for line in lines
        stripped = strip(line)
        if startswith(stripped, '#') || isempty(stripped)
            in_para && !isempty(paragraph) && break  # end of first paragraph
            in_para = false
            continue
        end
        in_para = true
        push!(paragraph, stripped)
    end

    isempty(paragraph) && return missing
    return join(paragraph, ' ')
end
