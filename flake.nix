{
  description = "7aigent — AI agent for interactive codebase exploration";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Single combined Julia environment used by both codeTree (build/test)
        # and sandbox (runtime depot).  Adding a package here automatically
        # makes it available inside the sandbox without any other changes.
        juliaEnv = pkgs.julia.withPackages [
          # CodeTree.jl runtime dependencies
          "DBInterface" "DataFrames" "DataFramesMeta" "SHA" "SQLite" "Tables"
          "TreeSitter"
          # Sandbox kernel
          "IJulia"
        ];

        codeTree = pkgs.callPackage ./CodeTree.jl {
          cacert   = pkgs.cacert;
          inherit (pkgs) git;
          inherit juliaEnv;
        };
        sandbox = pkgs.callPackage ./sandbox {
          inherit codeTree juliaEnv;
          gvisor = pkgs.gvisor;
        };
        agent = pkgs.callPackage ./agent { };
        testCodebase = pkgs.stdenv.mkDerivation {
          name = "test-codebase";
          src = ./CodeTree.jl/test/test_codebase;
          installPhase = "cp -r . $out";
        };

      in {
        packages = {
          inherit codeTree sandbox agent;
          default = sandbox;
        };

        checks = {
          sandbox-e2e = pkgs.callPackage ./test/sandbox-vm.nix {
            inherit sandbox codeTree testCodebase;
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ julia sqlite gvisor python3Packages.pytest purescript spago nodejs ];
          shellHook = ''
            echo "7aigent dev shell"
            echo "  julia --project=CodeTree.jl       — work on the Julia package"
            echo "  nix build .#sandbox               — build the sandbox"
            echo "  nix build .#codeTree              — build and test CodeTree.jl"
            echo "  nix build .#agent                 — build the agent runner"
            echo "  spago test                        — run agent PureScript tests"
            echo "  npm install (in agent/)           — install JS deps locally"
            echo "  pytest sandbox/test/              — run sandbox tests (needs nix build .#sandbox first)"
            echo "  nix flake check                   — run all checks including VM test"
          '';
        };
      });
}
