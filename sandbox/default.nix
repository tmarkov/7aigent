{ stdenv
, lib
, callPackage
, julia
, cacert
, git
, gvisor
, bubblewrap
, closureInfo
, python3
, sandboxPackages
}:

let
  juliaEnv = julia.withPackages sandboxPackages.julia;

  # Raw Julia binary (not the makeWrapper shell script) so we can call it
  # directly from the OCI process spec without needing /bin/sh in the rootfs.
  juliaRaw = juliaEnv.passthru.julia;
  juliaSourceDepot = juliaEnv.passthru.projectAndDepot;
  sandboxPath = lib.makeBinPath ([ juliaRaw ] ++ sandboxPackages.programs);

  juliaDepot = stdenv.mkDerivation {
    pname = "7aigent-sandbox-julia-depot";
    version = "0.1.0";

    dontUnpack = true;
    nativeBuildInputs = [ juliaRaw ];

    buildPhase = ''
      export HOME=$TMPDIR
      mkdir -p $out
      ln -s ${juliaSourceDepot}/depot/packages $out/packages
      ln -s ${juliaSourceDepot}/depot/artifacts $out/artifacts
      ln -s ${juliaSourceDepot}/depot/registries $out/registries

      export JULIA_CPU_TARGET="x86-64-v3"
      export JULIA_DEPOT_PATH=$out
      export JULIA_PROJECT=${juliaSourceDepot}/project
      export JULIA_SSL_CA_ROOTS_PATH="${cacert}/etc/ssl/certs/ca-bundle.crt"
      export JULIA_PKG_SERVER=""

      ${juliaRaw}/bin/julia --startup-file=no \
        -e ${lib.escapeShellArg
          "using ${lib.concatStringsSep ", " sandboxPackages.julia}"}
    '';

    installPhase = "true";

    passthru.packageNames = sandboxPackages.julia;
  };

  codeTree = callPackage ../CodeTree.jl {
    inherit juliaEnv;
    sandboxJuliaDepot = juliaDepot;
  };

  repl = stdenv.mkDerivation {
    pname = "7aigent-sandbox-repl";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./SevenAigentREPL.jl
        ./SevenAigentREPL
        ./test/runtests.jl
      ];
    };

    nativeBuildInputs = [ juliaRaw git ];

    buildPhase = ''
      export HOME=$TMPDIR
      export JULIA_CPU_TARGET="x86-64-v3"
      export JULIA_DEPOT_PATH=$out/julia-depot:${codeTree}:${juliaDepot}
      export JULIA_PROJECT=${codeTree}/project
      export JULIA_SSL_CA_ROOTS_PATH="${cacert}/etc/ssl/certs/ca-bundle.crt"
      export JULIA_PKG_SERVER=""

      JULIA_LOAD_PATH=$PWD:@:@v#.#:@stdlib \
        ${juliaRaw}/bin/julia --startup-file=no test/runtests.jl

      mkdir -p $out/julia-depot $out/share/sandbox
      cp SevenAigentREPL.jl $out/share/sandbox/SevenAigentREPL.jl
      cp -r SevenAigentREPL $out/share/sandbox/SevenAigentREPL

      JULIA_LOAD_PATH=$out/share/sandbox:@:@v#.#:@stdlib \
        ${juliaRaw}/bin/julia --startup-file=no \
        -e 'using CodeTree; using IJulia; using SevenAigentREPL'
    '';

    installPhase = "true";

    passthru.juliaDepot = juliaDepot;
  };

  runtimeClosure = closureInfo {
    rootPaths = [
      juliaRaw
      codeTree
      juliaDepot
      repl
    ] ++ sandboxPackages.programs;
  };

  sandbox = stdenv.mkDerivation {
    pname = "7aigent-sandbox";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./7aigent-sandbox
        ./startup.jl
        ./rootfs
        ./test/test_launcher.py
      ];
    };

    installPhase = ''
      mkdir -p $out/bin $out/share/sandbox
      cp startup.jl $out/share/sandbox/startup.jl
      cat ${runtimeClosure}/store-paths > $out/share/sandbox/runtime-store-paths
      echo $out >> $out/share/sandbox/runtime-store-paths

      cp -r rootfs $out/share/sandbox/rootfs

      sed \
        -e "s|@rootfs_dir@|$out/share/sandbox/rootfs|g" \
        -e "s|@runsc@|${gvisor}/bin/runsc|g" \
        -e "s|@bwrap@|${bubblewrap}/bin/bwrap|g" \
        -e "s|@julia@|${juliaRaw}|g" \
        -e "s|@sandbox_out@|$out|g" \
        -e "s|@codeTree@|${codeTree}|g" \
        -e "s|@julia_depot@|${juliaDepot}|g" \
        -e "s|@repl_runtime@|${repl}|g" \
        -e "s|@sandbox_path@|${sandboxPath}|g" \
        7aigent-sandbox > $out/bin/7aigent-sandbox

      chmod +x $out/bin/7aigent-sandbox
    '';

    doInstallCheck = true;

    nativeInstallCheckInputs = [
      git
      (python3.withPackages (ps: [ ps.pytest ]))
    ];

    installCheckPhase = ''
      SANDBOX_LAUNCHER=$out/bin/7aigent-sandbox \
        pytest -x test/test_launcher.py
    '';

    meta = with lib; {
      description = "Sandboxed IJulia kernel for 7aigent codebase exploration";
      license = licenses.mit;
      mainProgram = "7aigent-sandbox";
      platforms = [ "x86_64-linux" ];
    };

    passthru = {
      julia = juliaRaw;
      inherit juliaDepot sandboxPath;
      replRuntime = repl;
      runtimePrograms = sandboxPackages.programs;
    };
  };

  structureCheck =
    assert sandbox.passthru.juliaDepot.drvPath == juliaDepot.drvPath;
    assert sandbox.passthru.replRuntime.drvPath == repl.drvPath;
    assert juliaDepot.passthru.packageNames == sandboxPackages.julia;
    assert repl.passthru.juliaDepot.drvPath == juliaDepot.drvPath;
    assert sandbox.passthru.runtimePrograms == sandboxPackages.programs;
    assert sandbox.passthru.sandboxPath ==
      lib.makeBinPath ([ sandbox.passthru.julia ] ++ sandboxPackages.programs);
    stdenv.mkDerivation {
      name = "sandbox-nix-structure";
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
      };
      installPhase = ''
        test "$(find . -type f -name '*.nix' | wc -l)" -eq 2
        touch $out
      '';
    };
in
{
  inherit codeTree juliaDepot repl sandbox structureCheck;
  juliaPackages = sandboxPackages.julia;
  programs = sandboxPackages.programs;
}
