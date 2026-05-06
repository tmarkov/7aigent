{
  description = "7aigent — AI agent for interactive codebase exploration";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs     = nixpkgs.legacyPackages.${system};
        codeTree = pkgs.callPackage ./CodeTree.jl { cacert = pkgs.cacert; inherit (pkgs) git; };
        sandbox  = pkgs.callPackage ./sandbox     { inherit codeTree; gvisor = pkgs.gvisor; };
      in {
        packages = {
          inherit codeTree sandbox;
          default = sandbox;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ julia sqlite gvisor python3Packages.pytest ];
          shellHook = ''
            echo "7aigent dev shell"
            echo "  julia --project=CodeTree.jl       — work on the Julia package"
            echo "  nix build .#sandbox               — build the sandbox"
            echo "  nix build .#codeTree              — build and test CodeTree.jl"
            echo "  pytest sandbox/test/              — run sandbox tests (needs nix build .#sandbox first)"
          '';
        };
      });
}
