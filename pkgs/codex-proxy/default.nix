{
  lib,
  stdenv,
  buildGoModule,
  # From nvfetcher
  src,
  version,
}:
(buildGoModule.override (oldAttrs: {
  GOFLAGS = [];
})) {
  pname = "codex-proxy";
  inherit version src;

  vendorHash = null;
  proxyVendor = false;

  # Vendor dir in upstream is broken (out of sync with go.mod).
  # Delete it before configurePhase so nixpkgs doesn't detect it and
  # try to use -mod=vendor.
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
