# Custom startup for 7aigent self-test workspace.
# Adds codebase-specific hints on top of default behaviour.

using CodeTree
using DataFrames, DataFramesMeta
using SevenAigentREPL

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

println("db ready: $(nrow(db.code)) nodes. Do not call load() — db persists across all tool calls.")
println()

if isfile("AGENTS.md")
    println("AGENTS.md present — read it first (system prompt step 1).")
    println()
end

@subset(db.code, :depth .== 1)[!, [:id, :name, :n_children, :summary]]
