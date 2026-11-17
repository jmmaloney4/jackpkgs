{
  lib,
  python313Packages,
  makeWrapper,
  # From nvfetcher
  src,
  version,
}: let
  # nixpkgs fastmcp-slim is meta.broken when mcp >= 2 (#465). Clear broken for this
  # package env; upstream fastmcp still builds against nixpkgs mcp 2.x here.
  pythonPkgs = python313Packages.overrideScope (_final: prev: {
    fastmcp-slim = prev.fastmcp-slim.overridePythonAttrs (old: {
      meta = old.meta // {broken = false;};
    });
    fastmcp = prev.fastmcp.overridePythonAttrs (_old: {
      doCheck = false;
      doInstallCheck = false;
    });
  });
  pythonEnv = pythonPkgs.python.withPackages (ps:
    with ps; [
      fastmcp
      httpx
      pyyaml
    ]);
in
  python313Packages.stdenv.mkDerivation {
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

    # Smoke: fastmcp imports under the overridden python env (addresses #465 runtime concern).
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      ${pythonEnv.interpreter} -c "import fastmcp"
      runHook postInstallCheck
    '';

    meta = {
      description = "FastMCP server for the YNAB API";
      homepage = "https://github.com/jmmaloney4/mcp-ynab";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
      mainProgram = "mcp-ynab";
    };
  }
