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

    # Install source into $out/CodeTree first so the manifest path entry
    # points to the final stable store path, making the precompile cache
    # valid for anyone who adds $out to JULIA_DEPOT_PATH + LOAD_PATH.
    mkdir -p $out/CodeTree/src/config
    cp Project.toml $out/CodeTree/
    cp src/*.jl $out/CodeTree/src/
    cp src/config/*.jl $out/CodeTree/src/config/

    # Build a project in $out/project with CodeTree injected as a path dep.
    # Using $out (not TMPDIR) as the project root ensures the precompile cache
    # hash is keyed to the stable store path, not an ephemeral build directory.
    mkdir -p $out/project
    cp ${juliaDepot}/project/Project.toml $out/project/
    cp ${juliaDepot}/project/Manifest.toml $out/project/
    chmod u+w $out/project/Project.toml $out/project/Manifest.toml

    echo 'CodeTree = "342842c8-1a2a-4ebb-ae0f-32d4c88624eb"' \
      >> $out/project/Project.toml

    printf '\n[[deps.CodeTree]]\ndeps = ["DBInterface", "DataFrames", "DataFramesMeta", "SHA", "SQLite", "Tables", "TreeSitter"]\nuuid = "342842c8-1a2a-4ebb-ae0f-32d4c88624eb"\npath = "%s"\n' \
      "$out/CodeTree" >> $out/project/Manifest.toml

    # Initialise a minimal git repo inside the test_codebase fixture so that
    # discover_files can use `git ls-files --others --exclude-standard` and
    # correctly honour .gitignore (required by R5).
    git -C "$CODETREE_SRC/test/test_codebase" init -q
    git -C "$CODETREE_SRC/test/test_codebase" add .

    # $out is the depot root: compiled cache lands in $out/compiled/
    export JULIA_PROJECT=$out/project
    export JULIA_DEPOT_PATH=$out:${juliaDepot}/depot
    export JULIA_SSL_CA_ROOTS_PATH="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export JULIA_PKG_SERVER=""
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME="Nix Build"
    export GIT_AUTHOR_EMAIL="nix@localhost"
    export GIT_COMMITTER_NAME="Nix Build"
    export GIT_COMMITTER_EMAIL="nix@localhost"

    ${juliaRaw}/bin/julia --startup-file=no \
      "$CODETREE_SRC/test/runtests.jl"

    # Precompile CodeTree into $out/compiled/ so the sandbox can load it
    # without any precompilation at runtime.
    #
    # JULIA_DEPOT_PATH=$out:${juliaDepot}/depot means:
    # - Julia searches ${juliaDepot}/depot/compiled/ first for existing caches
    #   (all transitive deps such as DataFrames, TreeSitter, etc. are already
    #   there, compiled by julia.withPackages — we leave them untouched)
    # - Only CodeTree is missing, so only CodeTree is compiled fresh into $out
    # - The resulting .ji records @depot/packages/... paths (using juliaDepot's
    #   packages/ directly, no extra symlink layer) which are identical to what
    #   juliaDepot itself uses — so cache fingerprints stay consistent
    JULIA_DEPOT_PATH=$out:${juliaDepot}/depot \
      ${juliaRaw}/bin/julia --startup-file=no -e 'using CodeTree; using IJulia'
  '';

  # Source, project, and compiled cache are all written to $out during
  # buildPhase; nothing left to do here.
  installPhase = "true";

  meta = with lib; {
    description = "Julia package providing the code/refs schema for codebase indexing and querying";
    license     = licenses.mit;
  };
}
