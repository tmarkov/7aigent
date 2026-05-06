{ stdenv, julia, lib, gvisor, codeTree, juliaEnv, cacert }:

let
  # juliaEnv is the single shared environment defined in flake.nix,
  # containing CodeTree's deps and IJulia.

  # Raw Julia binary (not the makeWrapper shell script) so we can call it
  # directly from the OCI process spec without needing /bin/sh in the rootfs.
  juliaRaw   = juliaEnv.passthru.julia;

  # Pre-built depot (packages + project) placed in the Nix store.
  juliaDepot = juliaEnv.passthru.projectAndDepot;
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

    # ── static rootfs skeleton (empty mount-point directories) ───────────
    cp -r rootfs $out/share/sandbox/rootfs

    # ── OCI config.json template ─────────────────────────────────────────
    # Build-time Nix store paths are baked in here.
    # Runtime placeholders that the launcher fills in: @WORKSPACE@ @SOCKETS_DIR@
    cat > $out/share/sandbox/config.json.template << EOCONFIG
{
  "ociVersion": "1.0.0",
  "process": {
    "terminal": false,
    "user": { "uid": 0, "gid": 0 },
    "args": [
      "${juliaRaw}/bin/julia",
      "-t", "2",
      "--startup-file=no",
      "$out/share/sandbox/startup.jl",
      "@SOCKETS_DIR@/kernel.json"
    ],
    "env": [
      "JULIA_DEPOT_PATH=/tmp/julia-depot:$out/julia-depot",
      "JULIA_PROJECT=${codeTree}/project",
      "JULIA_LOAD_PATH=@:@v#.#:@stdlib",
      "HOME=/home/julia",
      "JULIA_PKG_SERVER=",
      "PATH=${juliaRaw}/bin"
    ],
    "cwd": "/workspace"
  },
  "root": { "path": "rootfs", "readonly": true },
  "mounts": [
    { "destination": "/proc",       "type": "proc",  "source": "proc" },
    { "destination": "/dev",        "type": "tmpfs", "source": "tmpfs",
      "options": ["nosuid", "noexec", "mode=755", "size=65536k"] },
    { "destination": "/tmp",        "type": "tmpfs", "source": "tmpfs" },
    { "destination": "/home/julia", "type": "tmpfs", "source": "tmpfs" },
    { "destination": "/nix/store",  "type": "bind",  "source": "/nix/store",
      "options": ["rbind", "ro"] },
    { "destination": "/workspace",  "type": "bind",  "source": "@WORKSPACE@",
      "options": ["rbind", "rw"] },
    { "destination": "/workspace/.git", "type": "bind", "source": "@WORKSPACE@/.git", "options": ["rbind", "ro"] },
    { "destination": "/sockets",    "type": "bind",  "source": "@SOCKETS_DIR@",
      "options": ["rbind", "rw"] }
  ],
  "linux": {
    "namespaces": [
      { "type": "pid"     },
      { "type": "mount"   },
      { "type": "ipc"     },
      { "type": "uts"     },
      { "type": "network" }
    ]
  }
}
EOCONFIG

    # ── launcher script ───────────────────────────────────────────────────
    # Substitute build-time placeholders into the source template.
    sed \
      -e "s|@rootfs_dir@|$out/share/sandbox/rootfs|g" \
      -e "s|@config_template@|$out/share/sandbox/config.json.template|g" \
      -e "s|@runsc@|${gvisor}/bin/runsc|g" \
      7aigent-sandbox > $out/bin/7aigent-sandbox

    chmod +x $out/bin/7aigent-sandbox
  '';

  meta = with lib; {
    description = "Sandboxed IJulia kernel for 7aigent codebase exploration";
    license     = licenses.mit;
    mainProgram = "7aigent-sandbox";
  };
}

