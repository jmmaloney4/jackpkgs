# Tests for lib/helm-chart.nix — mkHelmChartFromGitHub
#
# Validates the function produces correct derivation attributes without
# actually building (we use lib.fakeHash and inspect the result attrset).
{
  lib,
  pkgs,
}: let
  inherit (import ../lib/helm-chart.nix {inherit lib pkgs;}) mkHelmChartFromGitHub;

  # Build a minimal chart derivation for attribute inspection
  example = mkHelmChartFromGitHub {
    pname = "test-chart";
    version = "1.0.0";
    owner = "example";
    repo = "example-repo";
    hash = lib.fakeHash;
    chartSubdir = "charts/example";
  };

  # Build with custom rev
  exampleCustomRev = mkHelmChartFromGitHub {
    pname = "custom-rev-chart";
    version = "2.0.0";
    owner = "example";
    repo = "example-repo";
    hash = lib.fakeHash;
    chartSubdir = "chart";
    rev = "chart-2.0.0";
  };

  # Build with buildPhase
  exampleWithBuild = mkHelmChartFromGitHub {
    pname = "build-phase-chart";
    version = "3.0.0";
    owner = "example";
    repo = "example-repo";
    hash = lib.fakeHash;
    chartSubdir = "charts/example";
    buildPhase = ''
      echo "building"
    '';
  };
in {
  # Core attributes
  testPname = {
    expr = example.pname;
    expected = "test-chart";
  };

  testVersion = {
    expr = example.version;
    expected = "1.0.0";
  };

  # Derivation name follows pname-version convention
  testName = {
    expr = example.name;
    expected = "test-chart-1.0.0";
  };

  # Custom rev doesn't affect version
  testCustomRevVersion = {
    expr = exampleCustomRev.version;
    expected = "2.0.0";
  };

  testCustomRevName = {
    expr = exampleCustomRev.name;
    expected = "custom-rev-chart-2.0.0";
  };

  # buildPhase defaults to empty
  testDefaultBuildPhase = {
    expr = example.buildPhase;
    expected = "";
  };

  # buildPhase is passed through when provided
  testCustomBuildPhase = {
    expr = lib.strings.removeSuffix "\n" exampleWithBuild.buildPhase;
    expected = "echo \"building\"";
  };

  # dontConfigure is always true
  testDontConfigure = {
    expr = example.dontConfigure;
    expected = true;
  };

  # Install phase contains the chartSubdir
  testInstallPhaseContainsSubdir = {
    expr = lib.strings.hasInfix "charts/example" example.installPhase;
    expected = true;
  };
}
