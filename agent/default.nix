{
  lib,
  mkSpagoDerivation,
  nodejs,
  purescript,
  spago,
  zeromq,
  pkg-config,
  makeWrapper,
  esbuild,
  julia,
  sandbox,
}:

mkSpagoDerivation {
  pname = "7aigent";
  version = "0.0.1";
  src = ./.;
  spagoYaml = ./spago.yaml;
  spagoLock = ./spago.lock;

  nativeBuildInputs = [
    purescript
    spago
    nodejs
    pkg-config
    makeWrapper
    esbuild
    julia
  ];
  buildInputs = [ zeromq ];

  buildNodeModulesArgs = {
    inherit nodejs;
    npmRoot = ./.;
  };

  buildPhase = ''
    spago bundle --module Main --outfile index.js --bundle-type app --platform node \
      --bundler-args "--external:zeromq"
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    spago test --main Test.Main
    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out/bin $out/lib/7aigent
    cp index.js $out/lib/7aigent/
    cp -r node_modules $out/lib/7aigent/
    # Default workspace config files, copied into new workspaces by A2a.
    cp -r config $out/lib/7aigent/

    makeWrapper ${nodejs}/bin/node $out/bin/7aigent \
      --add-flags "$out/lib/7aigent/index.js" \
      --prefix PATH : ${sandbox}/bin \
      --set AGENT_CONFIG_DIR "$out/lib/7aigent/config"
  '';

  meta = with lib; {
    description = "ReACT agent runner for 7aigent codebase exploration";
    mainProgram = "7aigent";
  };
}
