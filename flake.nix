{
  description = "7aigent — AI agent for interactive codebase exploration";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    mkSpagoDerivation = {
      url = "github:jeslie0/mkSpagoDerivation";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, mkSpagoDerivation, purescript-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            mkSpagoDerivation.overlays.default
            purescript-overlay.overlays.default
          ];
        };

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
          python3 = pkgs.python3;
        };
        agent = pkgs.callPackage ./agent {
          spago = pkgs.spago-unstable;
          purescript = pkgs.purs;
          inherit sandbox;
        };
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
          agent-e2e = pkgs.callPackage ./test/agent-vm.nix {
            inherit agent testCodebase;
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            julia
            sqlite
            gvisor
            python3Packages.pytest
            python3Packages.jupyter-client
            purs
            spago-unstable
            nodejs
          ];
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
