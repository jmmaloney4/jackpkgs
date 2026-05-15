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

  # Upstream vendor dir is broken. Delete it, don't proxy it, and
  # let nixpkgs fetch dependencies via module proxy.
  vendorHash = null;
  proxyVendor = false;
  deleteVendor = true;
  
  # allowGoReference might affect GOFLAGS (specifically -trimpath)
  allowGoReference = true;

  # Delete vendor again to be sure (in case deleteVendor runs too late)
  preConfigurePhase = ''
    rm -rf vendor
  '';

  doCheck = false;

  # The build says "Building subPackage ./cmd/claude-code-proxy-worker"
  # So the binary is likely named "claude-code-proxy-worker"
  installPhase = ''
    mkdir -p $out/bin
    # Try both possible binary names
    cp -f claude-code-proxy-worker $out/bin/claude-code-proxy-worker 2>/dev/null || cp -f codex-proxy $out/bin/codex-proxy
    # If both fail, the build will fail
  '';

  meta = {
    description = "Expose ChatGPT Codex through standard OpenAI APIs";
    homepage = "https://github.com/dvcrn/codex-proxy";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "codex-proxy";
  };
}
