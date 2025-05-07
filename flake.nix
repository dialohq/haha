{
  description = "HaHa Nix Flake";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nix-filter.url = "github:numtide/nix-filter";
  inputs.nixpkgs.inputs.flake-utils.follows = "flake-utils";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/6bf084c4ea625dc3d6b94138df0cab9a9c7b9298";
  inputs.ocaml-overlays.url = "github:nix-ocaml/nix-overlays/d4ac32c12590b5ce8a756374a20476af8769f839";

  outputs = {
    self,
    nixpkgs,
    ocaml-overlays,
    flake-utils,
    nix-filter,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          ocaml-overlays.overlays.default
          (final: prev: {ocamlPackages = prev.ocaml-ng.ocamlPackages_5_3;})
        ];
      };
    in rec {
      packages = pkgs.callPackage ./nix/packages.nix {inherit nix-filter pkgs;};
      devShells = {
        default = pkgs.mkShell {
          inputsFrom = [packages.default packages.examples];
          buildInputs = with pkgs;
          with ocamlPackages; [
            ocamlformat
            ocaml-lsp
            h2spec
            utop

            alejandra
          ];
        };
      };
    });
}
