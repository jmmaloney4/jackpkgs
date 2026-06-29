{
  lib,
  rustPlatform,
  # From nvfetcher
  src,
  version,
  pkg-config,
  openssl,
}:
rustPlatform.buildRustPackage {
  pname = "dbn-cli";
  inherit version src;

  # The workspace ships its own Cargo.lock and depends only on crates.io
  # registry packages (no git dependencies), so the lockfile can be read
  # straight from the fetched source with no outputHashes.
  cargoLock.lockFile = src + "/Cargo.lock";

  # Build only the CLI crate from the workspace.
  buildAndTestSubdir = "rust/dbn-cli";

  nativeBuildInputs = [pkg-config];
  buildInputs = [openssl];

  # Link against the nix-provided OpenSSL rather than a vendored copy.
  OPENSSL_NO_VENDOR = "1";

  meta = {
    description = "CLI tool for working with Databento Binary Encoding (DBN) files and streams";
    homepage = "https://github.com/databento/dbn";
    license = lib.licenses.asl20;
    maintainers = [];
    platforms = lib.platforms.all;
    mainProgram = "dbn";
  };
}
