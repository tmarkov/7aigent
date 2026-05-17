using CodeTree
using DataFrames, DataFramesMeta
using SevenAigentREPL

Base.show(io::IO, df::DataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::SubDataFrame; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::CodeTree.CodeTree; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)
Base.show(io::IO, df::CodeTree.CodeSymbols; kwargs...) =
    SevenAigentREPL.llm_show_dataframe(io, df; kwargs...)

global db = CodeTree.load("/workspace")
SevenAigentREPL.bind!("/workspace", db)
db.code
