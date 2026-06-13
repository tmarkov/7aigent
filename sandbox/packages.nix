{ pkgs }:

{
  # S25: Julia packages available inside the sandbox.
  julia = [
    "DBInterface"
    "DataFrames"
    "DataFramesMeta"
    "SHA"
    "SQLite"
    "Tables"
    "TreeSitter"
    "IJulia"
  ];

  # S27: General programs available on PATH inside the sandbox.
  programs = with pkgs; [
    coreutils
    bash
    iputils
    python3
    git
    gnumake
    gcc
  ];
}
