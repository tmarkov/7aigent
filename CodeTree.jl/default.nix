{ stdenv, julia, lib }:

stdenv.mkDerivation {
  pname   = "CodeTree";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ julia ];

  buildPhase = ''
    export HOME=$TMPDIR
    export JULIA_DEPOT_PATH=$TMPDIR/julia-depot
    julia --project=. -e '
      using Pkg
      Pkg.instantiate()
      include("test/runtests.jl")
    '
  '';

  # Install into $out/CodeTree/ so that callers can push $out onto
  # Julia's LOAD_PATH and load the package with `using CodeTree`.
  # Julia searches LOAD_PATH entries for subdirectories named after
  # the package (i.e. CodeTree/src/CodeTree.jl).
  installPhase = ''
    mkdir -p $out/CodeTree/src
    cp Project.toml $out/CodeTree/
    cp src/CodeTree.jl $out/CodeTree/src/
  '';

  meta = with lib; {
    description = "Julia package providing the code/refs schema for codebase indexing and querying";
    license     = licenses.mit;
  };
}
