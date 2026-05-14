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

  # Vendor dir in upstream is out of sync with go.mod; delete it and use module proxy
  vendorHash = null;
  proxyVendor = false;
  deleteVendor = true;

  # Tell Go to fetch from module proxy instead of using vendor directory
  GOFLAGS = [ "-mod=mod" ];

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
