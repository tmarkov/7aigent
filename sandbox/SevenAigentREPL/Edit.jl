# Edit.jl — RA33: Base.replace override that prints substitution count.

"""
    Base.replace(s::String, pat_repl::Pair; count) -> String

Extension of `Base.replace` for `String` first arguments. Performs the
standard replacement and additionally prints the number of substitutions
made to stdout:

    replaced N occurrence(s)

where `N` is the number of non-overlapping matches of the pattern in `s`,
capped by the `count` keyword argument when supplied. This makes silent
no-op replacements immediately visible in an interactive session.
"""
function Base.replace(s::String, pat_repl::Pair; count::Integer = typemax(Int))
    n_matches = Base.count(first(pat_repl), s)
    n_replaced = min(n_matches, Int(count))
    # Dispatch to AbstractString method via SubString to avoid recursion.
    result = Base.replace(SubString(s, 1, lastindex(s)), pat_repl; count = Int(count))
    println("replaced $n_replaced occurrence(s)")
    return result
end
