{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      flake-parts,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { config, pkgs, ... }:
        {
          packages = {
            inherit (pkgs.callPackage ./packages/default.nix { })
              buck2
              rust-project
              ;
          };

          # mkShellNoCC to avoid shadowing the system C compiler on macOS
          devShells.default = pkgs.mkShellNoCC {
            nativeBuildInputs = [
              config.packages.buck2
              config.packages.rust-project
            ];
          };
        };
    };
}
