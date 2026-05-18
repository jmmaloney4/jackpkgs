{
  bun2nix,
  lib,
  src,
  version,
}:
bun2nix.mkDerivation {
  pname = "gemini-proxy";
  inherit src version;

  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ./bun.nix;
  };

  # Entry point for bundling
  module = "src/index.ts";

  # Remove upstream binary lockfile so bun uses our text lockfile instead
  postUnpack = ''
    rm -f source/bun.lockb
    cp ${./bun.lock} source/bun.lock
  '';

  # Don't minify the server binary
  removeBunBuildFlags = ["--minify"];

  meta = with lib; {
    description = "Self-hosted OpenAI-compatible HTTP proxy that translates requests to Google Gemini via Cloud Code Assist API";
    homepage = "https://github.com/KashifKhn/gemini-proxy";
    license = licenses.mit;
    maintainers = with maintainers; [jmmaloney4];
    platforms = platforms.unix;
    mainProgram = "gemini-proxy";
  };
}
