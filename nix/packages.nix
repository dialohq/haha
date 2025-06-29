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

    doCheck = true;
    checkInputs = [alcotest];

    propagatedBuildInputs = [cstruct hpack ppx_deriving];
  };

  h2inspect = buildDunePackage {
    pname = "h2inspect";
    version = "0.0.1";

    src = with nix-filter.lib;
      filter {
        root = ./..;
        include = ["dune-project" "h2inspect" "h2inspect.opam"];
      };

    propagatedBuildInputs = [ocolor ppx_deriving eio_main h2kit];
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
      h2kit

      eio_main
      uri
    ];
  };
}
