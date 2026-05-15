{
  lib,
  buildGoModule,
  # From nvfetcher
  src,
  version,
}:
buildGoModule {
  pname = "codex-proxy";
  inherit version src;

  # Upstream does not ship a vendor directory at tag 1.0.0, so let nixpkgs
  # build a vendor derivation from go.mod/go.sum.
  vendorHash = "sha256-arq8l6fdS9tezKoO3FJPe5Y0zn1r03Hm1bBfesGv3dU=";

  # Build the actual CLI entrypoint, not the Cloudflare worker stub.
  subPackages = [ "cmd/codex-proxy" ];

  doCheck = false;

  meta = {
    description = "Expose ChatGPT Codex through standard OpenAI APIs";
    homepage = "https://github.com/dvcrn/codex-proxy";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "codex-proxy";
  };
}
