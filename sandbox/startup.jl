# Startup script for the 7aigent sandbox kernel.
# Loads CodeTree.jl then starts the IJulia kernel.
# The connection file path is passed as the first positional argument.
# CODETREE_PATH env var must point to the CodeTree.jl Nix store path.
let codetree = get(ENV, "CODETREE_PATH", nothing)
    codetree !== nothing && push!(LOAD_PATH, codetree)
end

using CodeTree
using IJulia

IJulia.run_kernel()
