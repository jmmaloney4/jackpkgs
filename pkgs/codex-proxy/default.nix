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

  # The upstream vendor directory is out of sync with go.mod.
  # Run 'go mod vendor' in postUnpack to regenerate it before
  # buildGoModule's configurePhase sees it.
  vendorHash = null;
  
  postUnpack = ''
    cd "$sourceRoot"
    echo "Regenerating vendor directory to sync with go.mod..."
    go mod vendor
  '';

  doCheck = false;

  installPhase = ''
    mkdir -p $out/bin
    # Build output says "Building subPackage ./cmd/claude-code-proxy-worker"
    cp claude-code-proxy-worker $out/bin/codex-proxy
  '';

  meta = {
    description = "Expose ChatGPT Codex through standard OpenAI APIs";
    homepage = "https://github.com/dvcrn/codex-proxy";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "codex-proxy";
  };
}
