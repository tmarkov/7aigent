# Default startup: keep the important REPL behavior explicit in the workspace
# bootstrap so the model sees it directly, while delegating helper logic to
# SevenAigentREPL.

using CodeTree
using DataFrames, DataFramesMeta
using SevenAigentREPL

SevenAigentREPL.patch_ioproperties!()

Base.show(io::IO, df::DataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::SubDataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::CodeTree.CodeTree; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::CodeTree.CodeSymbols; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)

global db = CodeTree.load("/workspace")
SevenAigentREPL.init!("/workspace", db)
