{
  nix-filter,
  pkgs,
}:
with pkgs.ocamlPackages; rec {
  h2kit = buildDunePackage {
    pname = "h2kit";
    version = "0.0.1";

    src = with nix-filter.lib;
      filter {
        root = ./..;
        include = ["dune-project" "h2kit" "h2kit.opam"];
      };

    propagatedBuildInputs = [angstrom faraday cstruct hpack alcotest ppx_deriving];
  };

  default = buildDunePackage {
    pname = "haha";
    version = "0.0.1";

    src = with nix-filter.lib;
      filter {
        root = ./..;
        include = ["dune-project" "lib" "haha.opam"];
      };

    buildInputs = [
      eio_main
      angstrom
      faraday
      h2kit
      yojson
      uuidm
    ];
  };

  examples = buildDunePackage {
    pname = "haha-examples";
    version = "0.0.1";

    src = with nix-filter.lib;
      filter {
        root = ./..;
        include = ["dune-project" "examples" "haha-examples.opam"];
      };

    buildInputs = [
      default

      eio_main
      uri
    ];
  };
}
