{ lib, stdenv, buildNpmPackage, nodejs, purescript, spago, zeromq, pkg-config, makeWrapper }:

# Pre-fetch all PureScript registry packages as a fixed-output derivation.
# This mirrors the pattern buildNpmPackage uses for npm deps: network access is
# allowed here (and hash-verified), then the main build runs fully offline.
let
  spagoDeps = stdenv.mkDerivation {
    name = "7aigent-agent-spago-deps";
    src  = ./.;  # needs spago.yaml + spago.lock

    nativeBuildInputs = [ spago nodejs ];

    buildPhase = ''
      export HOME=$TMPDIR
      spago install --offline false
    '';

    # spago v2 (0.21+) stores packages under XDG_DATA_HOME (~/.local/share/spago).
    installPhase = ''
      cp -r $HOME/.local/share/spago $out
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    # Update this hash by running:
    #   nix build .#spagoDeps 2>&1 | grep "got:"
    # after editing spago.yaml or spago.lock.
    outputHash = lib.fakeHash;
  };

in buildNpmPackage {
  pname   = "7aigent";
  version = "0.0.1";
  src     = ./.;

  # Update with: nix run nixpkgs#prefetch-npm-deps agent/package-lock.json
  npmDepsHash = lib.fakeHash;

  # pkg-config + zeromq: required to compile the zeromq native Node.js addon.
  # purescript + spago: compile PureScript source and run tests.
  # makeWrapper: wrap the installed Node.js entry point.
  nativeBuildInputs = [ purescript spago nodejs pkg-config makeWrapper ];
  buildInputs       = [ zeromq ];

  buildPhase = ''
    runHook preBuild

    # Inject pre-fetched PureScript packages into the location spago expects.
    export HOME=$TMPDIR
    mkdir -p $HOME/.local/share
    ln -s ${spagoDeps} $HOME/.local/share/spago

    spago bundle-app --main Main --to index.js

    runHook postBuild
  '';

  # buildNpmPackage defaults to doCheck = false; we enable it here so that
  # the PureScript test suite runs as part of `nix build`.
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    export HOME=$TMPDIR
    mkdir -p $HOME/.local/share
    ln -sf ${spagoDeps} $HOME/.local/share/spago

    spago test --main Test.Main

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/7aigent
    cp index.js $out/lib/7aigent/
    cp -r node_modules $out/lib/7aigent/
    # Default workspace config files, copied into new workspaces by A2a.
    cp -r config $out/lib/7aigent/

    makeWrapper ${nodejs}/bin/node $out/bin/7aigent \
      --add-flags "$out/lib/7aigent/index.js"

    runHook postInstall
  '';

  meta = with lib; {
    description = "ReACT agent runner for 7aigent codebase exploration";
    mainProgram = "7aigent";
  };
}
