# Assembles the built-in per-language entries into DEFAULT_CONFIG.

"""
    DEFAULT_CONFIG :: LanguageConfig

Built-in language configuration covering C/C++, Julia, and Markdown.
Used as the default when `load` is called without an explicit `config`.

To customise a single language without discarding the others, use
`merge_config`:

```julia
my_cpp = LanguageEntry(...)
config  = merge_config(DEFAULT_CONFIG, Dict("cpp" => my_cpp))
db      = load("/workspace", config)
```
"""
const DEFAULT_CONFIG = LanguageConfig(Dict(
    "cpp"      => CPP_ENTRY,
    "julia"    => JULIA_ENTRY,
    "markdown" => MARKDOWN_ENTRY,
))
