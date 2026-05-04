{ stdenv, julia, lib, codeTree }:

let
  # All external Julia packages come from nixpkgs — no depot, no Manifest.toml.
  juliaEnv = julia.withPackages [ "RemoteREPL" ];
in
stdenv.mkDerivation {
  pname   = "7aigent-sandbox";
  version = "0.1.0";

  src = ./.;

  installPhase = ''
    mkdir -p $out/bin $out/share/sandbox

    cp startup.jl $out/share/sandbox/

    cat > $out/bin/7aigent-sandbox << EOF
    #!/bin/sh
    export CODETREE_PATH="${codeTree}"
    exec ${juliaEnv}/bin/julia \\
      --startup-file=no \\
      $out/share/sandbox/startup.jl "\$@"
    EOF

    chmod +x $out/bin/7aigent-sandbox
  '';

  meta = with lib; {
    description = "Sandboxed Julia REPL for 7aigent codebase exploration";
    license     = licenses.mit;
    mainProgram = "7aigent-sandbox";
  };
}
