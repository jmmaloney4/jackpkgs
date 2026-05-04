{
  lib,
  rustPlatform,
  stdenv,
  # From nvfetcher
  src,
  version,
  nvCargoLock,
}:
rustPlatform.buildRustPackage rec {
  pname = "tod";
  inherit version src;

  cargoLock = {
    lockFile = nvCargoLock."Cargo.lock".lockFile;
    outputHashes = nvCargoLock."Cargo.lock".outputHashes;
  };

  nativeBuildInputs = [];
  buildInputs = [];

  # Skip tests that try to create config files in directories that don't exist in Nix sandbox
  checkFlags = [
    "--skip"
    "filters::tests::test_get_next_task"
    "--skip"
    "lists::tests::test_label"
    "--skip"
    "projects::tests::test_get_next_task"
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
