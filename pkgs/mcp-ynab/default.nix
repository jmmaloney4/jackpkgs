{
  lib,
  python312Packages,
  makeWrapper,
  # From nvfetcher
  src,
  version,
}: let
  pythonEnv = python312Packages.python.withPackages (ps:
    with ps; [
      fastmcp
      httpx
      pyyaml
    ]);
in
  python312Packages.stdenv.mkDerivation {
    pname = "mcp-ynab";
    inherit version src;

    nativeBuildInputs = [makeWrapper];

    # No build phase -- it's a single-file Python app
    dontBuild = true;

    installPhase = ''
      mkdir -p $out/lib/mcp-ynab
      cp main.py $out/lib/mcp-ynab/
      makeWrapper ${pythonEnv.interpreter} $out/bin/mcp-ynab \
        --add-flags $out/lib/mcp-ynab/main.py
    '';

    # No upstream tests in Nix build
    doCheck = false;

    meta = {
      description = "FastMCP server for the YNAB API";
      homepage = "https://github.com/jmmaloney4/mcp-ynab";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
      mainProgram = "mcp-ynab";
    };
  }
