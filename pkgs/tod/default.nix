{
  lib,
  rustPlatform,
  stdenv,
  pkg-config,
  openssl,
  # From nvfetcher
  src,
  version,
  cargoLock,
}:
rustPlatform.buildRustPackage rec {
  pname = "tod";
  inherit version src;

  cargoLock = {
    lockFile = cargoLock."Cargo.lock".lockFile;
    outputHashes = cargoLock."Cargo.lock".outputHashes;
  };

  nativeBuildInputs = [pkg-config];
  buildInputs = [openssl];

  # Skip tests that try to create config files in directories that don't exist in Nix sandbox
  checkFlags = [
    "--skip"
    "args::tests::test_config"
    "--skip"
    "config::tests::test_config_initialize"
    "--skip"
    "config::tests::test_get_config"
  ];

  meta = with lib; {
    description = "A Todoist CLI client";
    homepage = "https://github.com/alanvardy/tod";
    license = licenses.unlicense;
    platforms = platforms.linux ++ platforms.darwin;
    maintainers = [];
    mainProgram = "tod";
  };
}
