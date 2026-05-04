# Startup script for the 7aigent sandbox REPL.
# Invoked by the sandbox wrapper with CODETREE_PATH set to the
# CodeTree.jl Nix store path ($out from its derivation).

# Make CodeTree.jl loadable.  The Nix derivation installs it as:
#   ${codeTree}/CodeTree/src/CodeTree.jl
# so pushing ${codeTree} onto LOAD_PATH lets Julia find it by name.
let codetree = get(ENV, "CODETREE_PATH", nothing)
    codetree !== nothing && push!(LOAD_PATH, codetree)
end

using CodeTree
using RemoteREPL

@info "7aigent sandbox ready"
@info "RemoteREPL listening on localhost:27754 — connect with: connect_repl()"

serve_repl()   # blocks; CTRL-C to stop
