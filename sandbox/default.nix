{ stdenv, julia, lib, gvisor, codeTree, juliaEnv, cacert, bubblewrap, coreutils, bash, iputils, closureInfo }:

let
  # juliaEnv is the single shared environment defined in flake.nix,
  # containing CodeTree's deps and IJulia.

  # Raw Julia binary (not the makeWrapper shell script) so we can call it
  # directly from the OCI process spec without needing /bin/sh in the rootfs.
  juliaRaw   = juliaEnv.passthru.julia;

  # Pre-built depot (packages + project) placed in the Nix store.
  juliaDepot = juliaEnv.passthru.projectAndDepot;

  runtimeClosure = closureInfo {
    rootPaths = [
      juliaRaw
      codeTree
      juliaDepot
      coreutils
      bash
      iputils
    ];
  };
in
stdenv.mkDerivation {
  pname   = "7aigent-sandbox";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ juliaRaw ];

  buildPhase = ''
    export HOME=$TMPDIR

    # Precompile all runtime packages (CodeTree + IJulia + transitive deps) into
    # $out/julia-depot/compiled/ with a fixed, reproducible JULIA_CPU_TARGET.
    #
    # Why not use juliaDepot's compiled caches directly?  juliaDepot is a
    # fixed-output derivation (FOD) whose .so files are compiled with the *native*
    # CPU of whatever machine performed the initial build.  That machine happened
    # to have avxvnni/hreset/ptwrite (Alder Lake extensions beyond AVX2).
    # gvisor's KVM virtual CPU does not expose those features via CPUID, so Julia's
    # cache validator rejects juliaDepot's .so on every sandbox launch.
    #
    # The Nix-correct fix is to compile with an explicit target here so the output
    # is reproducible regardless of the build machine.  x86-64-v3 (AVX2, no
    # Alder-Lake extensions) is the standard nixpkgs "modern x86" level and is
    # fully exposed by gvisor KVM.
    #
    # $out/julia-depot structure:
    #   compiled/  - freshly compiled x86-64-v3 caches (written by this step)
    #   packages/  - symlink to juliaDepot packages (source for compilation + @depot)
    #   artifacts/ - symlink to juliaDepot artifacts (JLL shared libraries)
    #   registries/- symlink to juliaDepot registries
    mkdir -p $out/julia-depot
    ln -s ${juliaDepot}/depot/packages   $out/julia-depot/packages
    ln -s ${juliaDepot}/depot/artifacts  $out/julia-depot/artifacts
    ln -s ${juliaDepot}/depot/registries $out/julia-depot/registries

    JULIA_CPU_TARGET="x86-64-v3" \
      JULIA_DEPOT_PATH=$out/julia-depot \
      JULIA_PROJECT=${codeTree}/project \
      JULIA_SSL_CA_ROOTS_PATH="${cacert}/etc/ssl/certs/ca-bundle.crt" \
      JULIA_PKG_SERVER="" \
      ${juliaRaw}/bin/julia --startup-file=no -e 'using CodeTree; using IJulia'
  '';

  installPhase = ''
    mkdir -p $out/bin $out/share/sandbox

    # ── startup script ────────────────────────────────────────────────────
    cp startup.jl $out/share/sandbox/startup.jl
    cat ${runtimeClosure}/store-paths > $out/share/sandbox/runtime-store-paths
    echo $out >> $out/share/sandbox/runtime-store-paths

    # ── static rootfs skeleton (empty mount-point directories) ───────────
    cp -r rootfs $out/share/sandbox/rootfs

    # ── launcher script ───────────────────────────────────────────────────
    # Substitute build-time placeholders into the source template.
    sed \
      -e "s|@rootfs_dir@|$out/share/sandbox/rootfs|g" \
      -e "s|@runsc@|${gvisor}/bin/runsc|g" \
      -e "s|@bwrap@|${bubblewrap}/bin/bwrap|g" \
      -e "s|@julia@|${juliaRaw}|g" \
      -e "s|@sandbox_out@|$out|g" \
      -e "s|@codeTree@|${codeTree}|g" \
      -e "s|@sandbox_path@|${juliaRaw}/bin:${coreutils}/bin:${bash}/bin:${iputils}/bin|g" \
      7aigent-sandbox > $out/bin/7aigent-sandbox

    chmod +x $out/bin/7aigent-sandbox
  '';

  meta = with lib; {
    description = "Sandboxed IJulia kernel for 7aigent codebase exploration";
    license     = licenses.mit;
    mainProgram = "7aigent-sandbox";
  };
}
