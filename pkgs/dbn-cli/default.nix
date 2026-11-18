{
  lib,
  rustPlatform,
  # From nvfetcher
  src,
  version,
  pkg-config,
  openssl,
  zstd,
}:
rustPlatform.buildRustPackage {
  pname = "dbn-cli";
  inherit version src;

  # A fixed-output vendor of the workspace's own Cargo.lock. Not
  # `cargoLock.lockFile = src + "/Cargo.lock"`: that reads the fetched source
  # during evaluation (import-from-derivation), so every consumer's eval has to
  # fetch dbn first and fails under `allow-import-from-derivation = false`
  # (cavinsresearch/zeus#5472). When nvfetcher bumps `version`, the build fails
  # with the new hash to put here.
  cargoHash = "sha256-Zjbe8YGyZIBIb32yp9FCqO+VxsKVp6HQX0GO/inCAic=";

  # Build only the CLI crate from the workspace.
  buildAndTestSubdir = "rust/dbn-cli";

  nativeBuildInputs = [pkg-config];
  buildInputs = [openssl zstd];

  # Link against the nix-provided OpenSSL rather than a vendored copy.
  OPENSSL_NO_VENDOR = "1";
  ZSTD_SYS_USE_PKG_CONFIG = "1";

  meta = {
    description = "CLI tool for working with Databento Binary Encoding (DBN) files and streams";
    homepage = "https://github.com/databento/dbn";
    license = lib.licenses.asl20;
    maintainers = [];
    platforms = lib.platforms.all;
    mainProgram = "dbn";
  };
}
