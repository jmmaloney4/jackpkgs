{
  lib,
  stdenv,
  buildGoModule,
  # From nvfetcher
  src,
  version,
}:
let
  # Custom configurePhase that skips 'go mod vendor' entirely
  customConfigurePhase = ''
    runHook preConfigure

    # Delete the broken vendor directory
    rm -rf vendor
    
    # Skip the nixpkgs go mod vendor step
    # Instead, we'll let Go fetch dependencies via module proxy
    echo "Skipping go mod vendor — using module proxy"

    runHook postConfigure
  '';
in
buildGoModule {
  pname = "codex-proxy";
  inherit version src;

  # Upstream vendor dir is broken. We'll skip vendor entirely.
  vendorHash = null;
  
  # Override the configurePhase to skip go mod vendor
  configurePhase = customConfigurePhase;
  
  # Tell Go to use module proxy instead of vendor
  GOFLAGS = [ "-mod=mod" "-trimpath" ];

  doCheck = false;

  installPhase = ''
    mkdir -p $out/bin
    # The binary is likely named "claude-code-proxy-worker" based on build output
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
