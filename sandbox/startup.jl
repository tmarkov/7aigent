# Startup script for the 7aigent sandbox kernel.
# CodeTree is available via JULIA_LOAD_PATH (set in OCI config).
# The connection file path is passed as the first positional argument.

using CodeTree
using IJulia

Core.eval(Base, :(have_color = false))
IJulia.run_kernel()
