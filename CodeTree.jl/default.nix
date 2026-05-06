{ stdenv, julia, lib, cacert, git, juliaEnv }:

let
  # juliaEnv is the single shared environment defined in flake.nix,
  # containing both CodeTree's deps and IJulia.
  juliaRaw       = juliaEnv.passthru.julia;
  juliaDepot     = juliaEnv.passthru.projectAndDepot;
in
stdenv.mkDerivation {
  pname   = "CodeTree";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ juliaRaw git ];

  buildPhase = ''
    export HOME=$TMPDIR
    export CODETREE_SRC=$(pwd)

    # Build a consistent project from the pre-built depot's manifest, then
    # inject CodeTree as a local path entry — no Pkg operations, no network.
    mkdir -p $TMPDIR/project
    cp ${juliaDepot}/project/Project.toml $TMPDIR/project/
    cp ${juliaDepot}/project/Manifest.toml $TMPDIR/project/
    chmod u+w $TMPDIR/project/Project.toml $TMPDIR/project/Manifest.toml

    # Add CodeTree to project deps
    echo 'CodeTree = "342842c8-1a2a-4ebb-ae0f-32d4c88624eb"' \
      >> $TMPDIR/project/Project.toml

    # Add CodeTree as a path entry in the manifest (deps list is required so Julia
    # knows which packages CodeTree is allowed to `using`).
    printf '\n[[deps.CodeTree]]\ndeps = ["DBInterface", "DataFrames", "DataFramesMeta", "SHA", "SQLite", "Tables", "TreeSitter"]\nuuid = "342842c8-1a2a-4ebb-ae0f-32d4c88624eb"\npath = "%s"\n' \
      "$CODETREE_SRC" >> $TMPDIR/project/Manifest.toml

    # Initialise a minimal git repo inside the test_codebase fixture so that
    # discover_files can use `git ls-files --others --exclude-standard` and
    # correctly honour .gitignore (required by R5).
    git -C "$CODETREE_SRC/test/test_codebase" init -q
    git -C "$CODETREE_SRC/test/test_codebase" add .

    mkdir -p $TMPDIR/depot
    export JULIA_PROJECT=$TMPDIR/project
    export JULIA_DEPOT_PATH=$TMPDIR/depot:${juliaDepot}/depot
    export JULIA_SSL_CA_ROOTS_PATH="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export JULIA_PKG_SERVER=""
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME="Nix Build"
    export GIT_AUTHOR_EMAIL="nix@localhost"
    export GIT_COMMITTER_NAME="Nix Build"
    export GIT_COMMITTER_EMAIL="nix@localhost"

    ${juliaRaw}/bin/julia --startup-file=no \
      "$CODETREE_SRC/test/runtests.jl"
  '';

  # Install into $out/CodeTree/ so that callers can push $out onto
  # Julia's LOAD_PATH and load the package with `using CodeTree`.
  # Julia searches LOAD_PATH entries for subdirectories named after
  # the package (i.e. CodeTree/src/CodeTree.jl).
  installPhase = ''
    mkdir -p $out/CodeTree/src
    cp Project.toml $out/CodeTree/
    cp src/*.jl $out/CodeTree/src/
  '';

  meta = with lib; {
    description = "Julia package providing the code/refs schema for codebase indexing and querying";
    license     = licenses.mit;
  };
}
