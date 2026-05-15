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

  # Upstream vendor dir is out of sync with go.mod. Let nixpkgs regenerate it.
  vendorHash = null;

  # Use overrideModAttrs to avoid GOFLAGS derivation conflict
  overrideModAttrs = true;
  GOFLAGS = [ "-mod=mod" "-trimpath" ];

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
