# Startup script for the 7aigent sandbox kernel.
# CodeTree and SevenAigentREPL are available via JULIA_LOAD_PATH (set in OCI
# config).
# The connection file path is passed as the first positional argument.

using CodeTree
using IJulia
using SevenAigentREPL

Core.eval(Base, :(have_color = false))

const SEVENAIGENT_STDIN_FIFO = "/sockets/stdin"
if ispath(SEVENAIGENT_STDIN_FIFO)
    const SEVENAIGENT_STDIN_IO = open(SEVENAIGENT_STDIN_FIFO, read=true, write=true)
    redirect_stdio(stdin=SEVENAIGENT_STDIN_IO)
end

IJulia.run_kernel()
