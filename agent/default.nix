{ pkgs
, rustPlatform
, makeWrapper
, sandbox
}:

rustPlatform.buildRustPackage {
  pname = "7aigent";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = [
    makeWrapper
    pkgs.rustfmt
    pkgs.clippy
  ];

  # Run tests during build
  doCheck = true;

  # Override check phase to run formatters, linters, and tests
  checkPhase = ''
    runHook preCheck

    echo "Running rustfmt check..."
    cargo fmt --check

    echo "Running clippy linter..."
    cargo clippy --all-targets --all-features -- -D warnings

    echo "Building tests..."
    cargo test --release --no-run

    # Set SANDBOX_PATH for integration tests
    export SANDBOX_PATH=${sandbox}/bin/7aigent-sandbox

    echo "Running unit tests (Tier 1)..."
    ${pkgs.coreutils}/bin/timeout 30 cargo test --release --lib

    echo "Running integration tests (Tier 1)..."
    ${pkgs.coreutils}/bin/timeout 180 cargo test --release --test integration_test

    runHook postCheck
  '';

  postInstall = ''
    # Rename binary from 'agent' to '7aigent'
    mv $out/bin/agent $out/bin/7aigent

    # Wrap agent binary with SANDBOX_PATH
    wrapProgram $out/bin/7aigent \
      --set SANDBOX_PATH ${sandbox}/bin/7aigent-sandbox
  '';

  meta = with pkgs.lib; {
    description = "7aigent - Autonomous AI Agent";
    license = licenses.mit;
  };
}
