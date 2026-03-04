{
  description = "7aigent - Autonomous AI Agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      naersk,
      pre-commit-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Naersk lib for building Rust projects
        naersk-lib = pkgs.callPackage naersk { };

        # Python environment with required packages
        pythonEnv = pkgs.python313.withPackages (
          ps: with ps; [
            # Testing
            pytest
            hypothesis

            # Subprocess management
            pexpect

            # Type checking (optional, for development)
            mypy

            # Development dependencies will be added as needed
          ]
        );

        # Pre-commit hooks configuration
        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            # Tier 1: Formatters and linters (fast, <1s)
            rustfmt = {
              enable = true;
              entry = "${pkgs.rustfmt}/bin/rustfmt --check";
            };
            black = {
              enable = true;
              entry = "${pkgs.black}/bin/black --check";
            };
            isort = {
              enable = true;
              entry = "${pkgs.isort}/bin/isort --check";
            };
            ruff = {
              enable = true;
              entry = "${pkgs.ruff}/bin/ruff check";
            };

            # Tier 1: Full test suite via Nix builds (~60s)
            # This runs all formatters, linters, unit tests, and integration tests
            build-agent = {
              enable = true;
              entry = "${pkgs.writeShellScript "build-agent" ''
                echo "Building agent (Tier 1: formatters + linters + all tests)..."
                ${pkgs.nix}/bin/nix build .#agent --no-link --print-build-logs
              ''}";
              pass_filenames = false;
              files = "\\.(rs|toml|nix)$";
            };
            build-orchestrator = {
              enable = true;
              entry = "${pkgs.writeShellScript "build-orchestrator" ''
                echo "Building orchestrator (formatters + linters + tests)..."
                ${pkgs.nix}/bin/nix build .#orchestrator --no-link --print-build-logs
              ''}";
              pass_filenames = false;
              files = "\\.(py|toml|nix)$";
            };
            build-sandbox = {
              enable = true;
              entry = "${pkgs.writeShellScript "build-sandbox" ''
                echo "Building sandbox (tests)..."
                ${pkgs.nix}/bin/nix build .#sandbox --no-link --print-build-logs
              ''}";
              pass_filenames = false;
              files = "(sandbox/|orchestrator/).*\\.(py|sh|nix)$";
            };
          };
        };

      in
      {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Rust toolchain
            rustc
            cargo
            rustfmt
            clippy
            rust-analyzer

            # Python environment
            pythonEnv

            # Python formatters and linters
            black
            isort
            ruff

            # Sandboxing
            bubblewrap

            # Version control
            git

            # Development tools
            direnv

            # Pre-commit hooks
            pre-commit
          ];

          # Environment variables
          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

          # Shell hook for additional setup
          shellHook = ''
            echo "🦀 Rust toolchain: $(rustc --version)"
            echo "🐍 Python: $(python --version)"
            echo "🔒 Bubblewrap: $(bwrap --version)"
            echo ""
            echo "Development environment loaded!"
            echo "Run 'pre-commit install' to set up git hooks"
          ''
          + pre-commit-check.shellHook;
        };
        packages = rec {
          # Build the agent (Rust) with embedded sandbox
          agent = pkgs.callPackage ./agent {
            sandbox = sandbox;
          };

          # Build the orchestrator (Python)
          orchestrator = pkgs.python313Packages.buildPythonApplication {
            pname = "7aigent-orchestrator";
            version = "0.1.0";
            src = ./orchestrator;

            # Use pyproject.toml for build
            pyproject = true;

            # Build system dependencies
            build-system = with pkgs.python313Packages; [
              setuptools
            ];

            # Propagated build inputs (runtime dependencies)
            propagatedBuildInputs = with pkgs.python313Packages; [
              pexpect
              textual
            ];

            # Check inputs (test and lint dependencies)
            nativeCheckInputs = with pkgs.python313Packages; [
              pytest
              hypothesis
            ];

            # Run checks (tests and linters)
            checkPhase = ''
              echo "Running black formatter check..."
              ${pkgs.black}/bin/black --check orchestrator/ tests/

              echo "Running isort check..."
              ${pkgs.isort}/bin/isort --check orchestrator/ tests/

              echo "Running ruff linter..."
              ${pkgs.ruff}/bin/ruff check orchestrator/ tests/

              echo "Running pytest tests..."
              ${pkgs.coreutils}/bin/timeout 120 pytest tests/ -v
            '';

            # Ensure checks are run
            doCheck = true;

            meta = with pkgs.lib; {
              description = "7aigent orchestrator - manages environments inside container";
              license = licenses.mit;
            };
          };

          # Build the sandbox script (bubblewrap wrapper)
          sandbox = pkgs.callPackage ./sandbox {
            orchestrator = self.packages.${system}.orchestrator;
          };

          # Default package
          default = self.packages.${system}.agent;
        };

        # Pre-commit checks
        checks = {
          inherit pre-commit-check;
        };
      }
    );
}
