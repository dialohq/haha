{
  nix-filter,
  ocamlPackages,
}:
with ocamlPackages; rec {
  hpack = buildDunePackage {
    pname = "hpack";
    version = "0.0.1";

    src = with nix-filter.lib;
      filter {
        root = ./..;
        include = ["dune-project" "hpack" "hpack.opam"];
      };

    propagatedBuildInputs = [angstrom faraday];
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
      alcotest
      angstrom
      faraday
      hex
      yojson
      base64
      uri
      hpack
    ];
  };
}
