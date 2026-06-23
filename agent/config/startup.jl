# Startup helpers for a 7aigent workspace.

using CodeTree
using DataFrames, DataFramesMeta
using SevenAigentREPL

# Display strings as raw content (no quotes/escapes), matching how DataFrames are shown.
Base.show(io::IO, ::MIME"text/plain", s::String) = print(io, s)
Base.show(io::IO, ::MIME"text/markdown", s::String) = print(io, s)

Base.show(io::IO, df::DataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::DataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::DataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, df::SubDataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::SubDataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::SubDataFrame) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, df::CodeTree.CodeTree; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::CodeTree.CodeTree) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::CodeTree.CodeTree) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, df::CodeTree.CodeSymbols; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, ::MIME"text/plain", df::CodeTree.CodeSymbols) =
    SevenAigentREPL.llm_show_dataframe(io, df)
Base.show(io::IO, ::MIME"text/markdown", df::CodeTree.CodeSymbols) =
    SevenAigentREPL.llm_show_dataframe(io, df)

global db = CodeTree.load("/workspace")
SevenAigentREPL.bind!("/workspace", db)
