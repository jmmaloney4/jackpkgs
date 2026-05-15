{
  lib,
  stdenv,
  buildGoModule,
  # From nvfetcher
  src,
  version,
}:
buildGoModule {
  pname = "codex-proxy";
  inherit version src;

  # Upstream vendor dir is broken (out of sync with go.mod).
  # Delete it in preConfigurePhase so nixpkgs doesn't try to use it.
  # With vendorHash = null and no vendor dir, nixpkgs should fall back
  # to fetching from module proxy.
  vendorHash = null;
  preConfigurePhase = ''
    rm -rf vendor
  '';

  doCheck = false;

  installPhase = ''
    mkdir -p $out/bin
    cp codex-proxy $out/bin/codex-proxy
  '';

  meta = {
    description = "Expose ChatGPT Codex through standard OpenAI APIs";
    homepage = "https://github.com/dvcrn/codex-proxy";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "codex-proxy";
  };
}
