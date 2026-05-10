# Default startup: index the workspace and bind the database to Main.db.
# Edit .7aigent/startup.jl in your workspace to customise this behaviour.

# Workaround: IJulia's stdio type is missing ioproperties in Julia 1.12+,
# which causes IOContext construction to fail when printing arrays/vectors.
try
    Base.eval(:(ioproperties(io::$(typeof(stdout))) = ImmutableDict{Symbol,Any}()))
catch e
    @warn "ioproperties patch failed" e
end

db = CodeTree.load("/workspace");
