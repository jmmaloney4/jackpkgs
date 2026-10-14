{
  lib,
  rustPlatform,
  pkg-config,
  openssl,
  cacert,
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

  nativeBuildInputs = [pkg-config];
  buildInputs = [openssl];
  # tod 0.19's reqwest 0.13 uses rustls-native-certs; Client::new() panics in
  # the Nix sandbox unless the CA bundle is on the check path.
  nativeCheckInputs = [cacert];
  env.SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  # Skip tests that try to create config files in directories that don't exist in Nix sandbox
  checkFlags = [
    "--skip"
    "filters::tests::test_get_next_task"
    "--skip"
    "lists::tests::test_label"
    "--skip"
    "projects::tests::test_get_next_task"
    "--skip"
    "debug::tests::buffer_redirect_tests_cannot_run_in_parallel"
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
