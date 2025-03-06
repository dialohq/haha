{
  description = "HaHa Nix Flake";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.inputs.flake-utils.follows = "flake-utils";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/6bf084c4ea625dc3d6b94138df0cab9a9c7b9298";
  inputs.ocaml-overlays.url = "github:nix-ocaml/nix-overlays/d4ac32c12590b5ce8a756374a20476af8769f839";

  outputs = {
    self,
    nixpkgs,
    ocaml-overlays,
    flake-utils,
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
      packages.default = pkgs.ocamlPackages.buildDunePackage {
        pname = "haha";
        version = "0.0.1";

        buildInputs = with pkgs.ocamlPackages; [
          eio_main
          angstrom
          faraday
          base64
        ];
      };
      devShells = {
        default = pkgs.mkShell {
          inputsFrom = [packages.default];
          buildInputs = with pkgs;
          with ocamlPackages; [
            ocamlformat
            ocaml-lsp
            h2spec
            alcotest
            hex
            yojson

            alejandra
          ];
        };
      };
    });
}
