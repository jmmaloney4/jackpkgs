{
  lib,
  rustPlatform,
  # From nvfetcher
  src,
  version,
}:
rustPlatform.buildRustPackage {
  pname = "codex-proxy-rs";
  inherit version src;

  # The crate ships its own Cargo.lock and depends only on crates.io
  # registry packages (no git dependencies), so the lockfile can be read
  # straight from the fetched source with no outputHashes.
  cargoLock.lockFile = src + "/Cargo.lock";

  # Integration tests bind localhost, which the sandbox forbids; the
  # devshell runs them via cargo-nextest instead.
  doCheck = false;

  meta = {
    description = "Rust port of codex-proxy: OpenAI-compatible reverse proxy for the ChatGPT Codex backend";
    homepage = "https://github.com/jmmaloney4/codex-proxy-rs";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "codex-proxy";
  };
}
