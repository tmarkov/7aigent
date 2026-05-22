{
  lib,
  stdenv,
  buildNpmPackage,
  nodejs,
  purescript,
  spago,
  zeromq,
  pkg-config,
  makeWrapper,
  git,
  esbuild,
  julia,
  cacert,
  sandbox,
}:

let
  # Fixed-output derivation: runs `spago install` to populate the spago
  # package cache, then copies it to $out (excluding .git dirs).
  # dontFixup avoids patchelf/strip failing on the registry git objects.
  #
  # To update after changing spago.yaml / spago.lock:
  #   1. Set outputHash = lib.fakeHash
  #   2. Run: nix build .#agent 2>&1 | grep "got:"
  #   3. Paste the "got:" hash here
  spagoDeps = stdenv.mkDerivation {
    name = "7aigent-spago-deps";
    src = ./.;

    nativeBuildInputs = [
      spago
      purescript
      git
      nodejs
      cacert
    ];

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-DpVGUCx6U1lCLAhHDZVZCvBGNbSbyx/ECSs4KA1zmP8=";

    buildPhase = ''
      export HOME=$TMPDIR
      export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      spago install
    '';

    installPhase = ''
      cp -r --no-preserve=mode $HOME/.cache/spago-nodejs $out
      find $out -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
    '';

    dontFixup = true;
  };

in
buildNpmPackage {
  pname = "7aigent";
  version = "0.0.1";
  src = ./.;

  # Update with: nix run nixpkgs#prefetch-npm-deps agent/package-lock.json
  npmDepsHash = "sha256-ITLCHv0KOcnLIn79HpXuhvDfo2pc9kskIrfasM08y08=";

  # pkg-config + zeromq: required to compile the zeromq native Node.js addon.
  # purescript + spago: compile PureScript source and run tests.
  # makeWrapper: wrap the installed Node.js entry point.
  # julia: needed at test time for A29/A30 (isPureDefinitionImpl spawns julia).
  nativeBuildInputs = [
    purescript
    spago
    nodejs
    pkg-config
    makeWrapper
    git
    esbuild
    julia
  ];
  buildInputs = [ zeromq ];

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    mkdir -p $HOME/.cache
    cp -r --no-preserve=mode ${spagoDeps} $HOME/.cache/spago-nodejs

    spago bundle --module Main --outfile index.js --bundle-type app --platform node \
      --bundler-args "--external:zeromq"

    runHook postBuild
  '';

  # buildNpmPackage defaults to doCheck = false; we enable it here so that
  # the PureScript test suite runs as part of `nix build`.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
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
      --add-flags "$out/lib/7aigent/index.js" \
      --prefix PATH : ${sandbox}/bin \
      --set AGENT_CONFIG_DIR "$out/lib/7aigent/config"

    runHook postInstall
  '';

  meta = with lib; {
    description = "ReACT agent runner for 7aigent codebase exploration";
    mainProgram = "7aigent";
  };
}
