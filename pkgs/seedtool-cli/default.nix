{
  lib,
  rustPlatform,
  fetchCrate,
  stdenv,
}:
rustPlatform.buildRustPackage rec {
  pname = "seedtool-cli";
  version = "0.4.0";

  src = fetchCrate {
    inherit pname version;
    hash = "sha256-iLNBhoUm9spN6iDOONWyt4MHu2Hz1OWG+pouc2ZjQbM=";
  };

  cargoHash = "sha256-AGU8eSyDBqu8hV9BbF4HxHLK+QSc/fbLVxiPsGcSmmc=";

  meta = with lib; {
    description = "Gordian seed tool for creating and managing seeds, mnemonics, and SSKR shares";
    homepage = "https://github.com/BlockchainCommons/seedtool-cli-rust";
    license = licenses.bsd2;
    maintainers = with maintainers; [];
    platforms = platforms.all;
    mainProgram = "seedtool";
  };
}
