{
  lib,
  pkgs,
}: let
  /**
  Build a Helm chart directory from a GitHub source repository.

  Produces a derivation whose `$out` contains the rendered chart files
  from `chartSubdir` within the fetched source. This is the standard
  pattern for Helm charts that only ship inside their upstream GitHub
  repo (no standalone OCI registry or chart tarball).

  The call-site attribute layout is deliberately regular so that
  Renovate's regex manager can detect and update versions automatically
  with a single match pattern — no multi-regex soup.

  Required attributes:
    pname        — Nix package name (e.g. "cert-manager-chart")
    version      — Semver string (e.g. "1.20.2")
    owner        — GitHub org or user
    repo         — GitHub repository name
    hash         — SRI hash for fetchFromGitHub (use `lib.fakeHash` during dev)
    chartSubdir  — path within the repo to the chart directory
                   (e.g. "deploy/charts/cert-manager")

  Optional attributes:
    rev          — ref template (default: "v${version}")
    buildPhase   — additional build steps before install (default: none)

  Example:

  ```nix
  jackpkgsLib.mkHelmChartFromGitHub {
    pname = "cert-manager-chart";
    version = "1.20.2";
    owner = "cert-manager";
    repo = "cert-manager";
    hash = "sha256-...";
    chartSubdir = "deploy/charts/cert-manager";
    buildPhase = ''
      sed -i 's/version: v0.0.0/version: ${version}/' deploy/charts/cert-manager/Chart.yaml
    '';
  }
  ```

  Renovate regex (single pattern for all call sites):

  ```
  mkHelmChartFromGitHub\s*\{[\s\S]*?pname\s*=\s*"(?<depName>[^"]+)";[\s\S]*?version\s*=\s*"(?<currentValue>[^"]+)";[\s\S]*?owner\s*=\s*"(?<owner>[^"]+)";[\s\S]*?repo\s*=\s*"(?<repo>[^"]+)";[\s\S]*?hash\s*=\s*"[^"]+";
  ```
  */
  mkHelmChartFromGitHub = {
    pname,
    version,
    owner,
    repo,
    hash,
    chartSubdir,
    rev ? "v${version}",
    buildPhase ? "",
  }:
    pkgs.stdenv.mkDerivation {
      inherit pname version;

      src = pkgs.fetchFromGitHub {
        inherit owner repo rev hash;
      };

      dontConfigure = true;
      inherit buildPhase;

      installPhase = ''
        mkdir -p $out
        cp -a ${lib.escapeShellArg chartSubdir}/* $out/
      '';
    };
in {inherit mkHelmChartFromGitHub;}
