{ pkgs
, orchestrator
}:

let
  # All packages available in the sandbox (minimal set)
  sandboxPackages = with pkgs; [
    # Essential for orchestrator
    python313
    bash
    coreutils
    findutils
    procps

    # For FHS compatibility
    glibc

    # For SSL certs
    cacert

    # Nix tools for shell_prefix support (nix develop, etc.)
    nix

    # The orchestrator itself
    orchestrator
  ];

  # Build an FHS-like environment
  sandboxEnv = pkgs.buildEnv {
    name = "7aigent-sandbox-env";
    paths = sandboxPackages;
    pathsToLink = [ "/bin" "/lib" "/share" "/etc" ];
  };

in
pkgs.stdenv.mkDerivation {
  pname = "7aigent-sandbox";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    pkgs.python313
    pkgs.python313Packages.pytest
  ];

  # Don't run check in the default position (before install)
  doCheck = true;
  doInstallCheck = true;

  # No build phase needed - we're just installing a script
  dontBuild = true;

  # Install the sandbox script
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cat > $out/bin/7aigent-sandbox << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Arguments: PROJECT_DIR [EXTRA_BWRAP_ARGS...]
PROJECT_DIR="''${1:?PROJECT_DIR required}"
shift

# Build bubblewrap command
exec ${pkgs.bubblewrap}/bin/bwrap \
  --unshare-all \
  --share-net \
  --new-session \
  --die-with-parent \
  \
  `# Mount /nix/store read-only (all packages available)` \
  --ro-bind /nix /nix \
  \
  `# Mount project directory read-write` \
  --bind "''${PROJECT_DIR}" /workspace \
  --chdir /workspace \
  \
  `# Set up essential filesystems` \
  --tmpfs /tmp \
  --proc /proc \
  --dev /dev \
  \
  `# FHS compatibility symlinks` \
  --symlink usr/bin /bin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  \
  `# Minimal /usr from our env` \
  --ro-bind ${sandboxEnv}/bin /usr/bin \
  --ro-bind ${sandboxEnv}/lib /usr/lib \
  \
  `# Resolve DNS` \
  --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
  --ro-bind-try /etc/hosts /etc/hosts \
  \
  `# Environment variables` \
  --setenv PATH "/usr/bin:${sandboxEnv}/bin" \
  --setenv PYTHONPATH "${orchestrator}/lib/python3.13/site-packages" \
  --setenv HOME "/tmp/home" \
  --unsetenv SESSION_MANAGER \
  \
  `# User-provided extra arguments` \
  "''$@" \
  \
  `# Execute orchestrator` \
  ${orchestrator}/bin/orchestrator
EOF

    chmod +x $out/bin/7aigent-sandbox

    runHook postInstall
  '';

  # Run integration tests AFTER install (installCheckPhase runs after installPhase)
  installCheckPhase = ''
    runHook preInstallCheck

    echo "Running sandbox integration tests..."

    # Set sandbox script path for tests (now it exists!)
    export SANDBOX_SCRIPT=$out/bin/7aigent-sandbox

    # Run pytest with timeout
    ${pkgs.coreutils}/bin/timeout 120 pytest tests/ -v --tb=short

    runHook postInstallCheck
  '';

  meta = with pkgs.lib; {
    description = "7aigent sandbox - bubblewrap-based isolation for orchestrator";
    license = licenses.mit;
  };
}
