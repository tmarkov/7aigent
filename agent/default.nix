{ pkgs
, naersk-lib
, makeWrapper
, sandbox
}:

naersk-lib.buildPackage {
  pname = "7aigent";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    pkgs.rustfmt
    pkgs.clippy
  ];

  # Enable the check phase
  doCheck = true;

  # Use naersk's cargoTestCommands instead of overriding checkPhase directly.
  # naersk wraps these with || true in the deps derivation (which uses dummy source),
  # so failures are suppressed there. In the main derivation, all commands must pass.
  cargoTestCommands = _: [
    ''cargo fmt -- --check''
    ''cargo clippy --all-targets --all-features -- -D warnings''
    ''cargo $cargo_options test $cargo_test_options''
  ];

  # overrideMain: attributes here only affect the main derivation, not agent-deps.
  # This keeps sandbox/orchestrator store paths out of the deps hash, so changing
  # non-Rust code doesn't invalidate the compiled dependency cache.
  overrideMain = old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [
      makeWrapper
      pkgs.python3
    ];

    # Set SANDBOX_PATH for integration tests
    SANDBOX_PATH = "${sandbox}/bin/7aigent-sandbox";

    # Set ORCHESTRATOR_PATH for tests that exercise the auxiliary LLM protocol.
    # The orchestrator source is a pure-stdlib Python package, so no extra deps needed.
    # Using a Nix path (not toString) ensures Nix copies it into the sandbox store.
    ORCHESTRATOR_PATH = ../orchestrator;

    postInstall = ''
      # Rename binary from 'agent' to '7aigent'
      mv $out/bin/agent $out/bin/7aigent

      # Wrap agent binary with SANDBOX_PATH
      wrapProgram $out/bin/7aigent \
        --set SANDBOX_PATH ${sandbox}/bin/7aigent-sandbox
    '';
  };

  meta = with pkgs.lib; {
    description = "7aigent - Autonomous AI Agent";
    license = licenses.mit;
  };
}
