# Tests for lib/default.nix -- the jackpkgs library AGGREGATOR itself.
#
# lib/default.nix is `{pkgs}: with pkgs.lib; rec { ... }`. There is no
# binding named `lib` in that scope: `with pkgs.lib;` brings nixpkgs lib's
# *attributes* into scope, not a name `lib`. Several exports are wired up
# with `import ./foo.nix {inherit lib;}` (or `{inherit lib pkgs;}`), which
# silently builds an attrset whose `lib` key is a thunk pointing at that
# undefined variable (jackpkgs#396).
#
# This is why the bug went unnoticed: every OTHER test file in this repo
# (tests/helm-chart.nix, tests/python-workspace-paths.nix, tests/lean.nix,
# ...) imports the underlying lib/*.nix file DIRECTLY with a correctly
# bound `lib` argument, bypassing lib/default.nix's own wiring entirely.
# `builtins.attrNames`/`isAttrs` on the aggregator's output also does not
# catch it: the broken `lib` thunk is lazy and is only forced once some
# downstream helper actually evaluates `lib.<fn>`.
#
# So these tests import `../lib/default.nix` itself (the ONLY argument it
# takes is `pkgs`) and re-run real invocations of each affected export --
# the same fixtures/expectations already proven against the underlying
# files directly -- but reached THROUGH the aggregator's own wiring, so a
# broken `inherit lib;` line actually fails the check instead of silently
# returning an unforced thunk.
{
  lib,
  pkgs,
}: let
  jackpkgsLib = import ../lib/default.nix {inherit pkgs;};

  # -------------------------------------------------------------------
  # helmChart (lib/default.nix:33, was `{inherit lib pkgs;}`)
  #
  # mkHelmChartFromGitHub's installPhase calls `lib.escapeShellArg`, so
  # building the derivation attrset and reading `.installPhase` forces
  # the `lib` thunk. Same fixture as tests/helm-chart.nix.
  # -------------------------------------------------------------------
  chart = jackpkgsLib.helmChart.mkHelmChartFromGitHub {
    pname = "test-chart";
    version = "1.0.0";
    owner = "example";
    repo = "example-repo";
    hash = lib.fakeHash;
    chartSubdir = "charts/example";
  };

  # -------------------------------------------------------------------
  # pythonWorkspacePaths (lib/default.nix:36, was `{inherit lib;}`)
  #
  # discoverPythonWorkspaceMembers calls into nodejs-helpers.nix's
  # expandWorkspaceGlob, which uses lib.hasInfix / lib.hasSuffix /
  # lib.removeSuffix / lib.filterAttrs / lib.attrNames -- forces `lib`
  # deeply, several call frames down. Same fixture as
  # tests/python-workspace-paths.nix.
  # -------------------------------------------------------------------
  fixturesRoot = ../tests/fixtures/python-workspace;
  workspaceA = fixturesRoot + "/standard";
  pyprojectA = workspaceA + "/pyproject.toml";

  # -------------------------------------------------------------------
  # justfile (lib/default.nix:30, always correct: `lib = pkgs.lib;`)
  # and lean (lib/default.nix:43, already fixed ahead of #396) --
  # included as regression controls: exercised through the aggregator so
  # a future edit that "fixes" them into the broken pattern is caught
  # here too, not just in their own dedicated test files.
  # -------------------------------------------------------------------
  recipe = jackpkgsLib.justfile.mkRecipe "greet" "say hi" ["echo hi"] false;
in {
  testHelmChartInstallPhaseForcesLib = {
    expr = lib.strings.hasInfix "charts/example" chart.installPhase;
    expected = true;
  };

  testHelmChartName = {
    expr = chart.name;
    expected = "test-chart-1.0.0";
  };

  testPythonWorkspacePathsDiscoversMembers = {
    expr = jackpkgsLib.pythonWorkspacePaths.discoverPythonWorkspaceMembers {
      workspaceRoot = workspaceA;
      pyprojectPath = pyprojectA;
    };
    expected = ["libs/api" "libs/dlt" "tools/apollo"];
  };

  testPythonWorkspaceSrcPathsForcesLib = {
    expr = jackpkgsLib.pythonWorkspacePaths.pythonWorkspaceSrcPaths {
      workspaceRoot = workspaceA;
      pyprojectPath = pyprojectA;
    };
    expected = ["libs/api/src" "libs/dlt/src" "tools/apollo/src"];
  };

  testJustfileRecipeControl = {
    expr = lib.strings.hasInfix "echo hi" recipe;
    expected = true;
  };

  testLeanParseToolchainControl = {
    expr = jackpkgsLib.lean.parseToolchain "leanprover/lean4:v4.34.0\n";
    expected = "v4.34.0";
  };

  # -------------------------------------------------------------------
  # mkFromYAML (lib/default.nix:66) -- uses only `with pkgs.lib;`-bound
  # names (removeSuffix), never a bare `lib.` reference, so it is not
  # part of the defect surface. Exercised anyway via the JSON-sidecar
  # fast path (no yq-go IFD needed) for completeness of "every export".
  # -------------------------------------------------------------------
  testMkFromYAMLJsonSidecar = {
    expr = jackpkgsLib.mkFromYAML {} (./fixtures/lib-default/example.yaml);
    expected = {
      greeting = "hello";
      count = 2;
    };
  };

  # -------------------------------------------------------------------
  # Pure `with pkgs.lib;` helpers -- not part of the defect surface
  # (no bare `lib.` references), forced directly for completeness.
  # -------------------------------------------------------------------
  testOnlyOnSystemsIncluded = {
    expr = jackpkgsLib.onlyOnSystems ["x86_64-linux"] "x86_64-linux" {foo = 1;};
    expected = {foo = 1;};
  };

  testOnlyOnSystemsExcluded = {
    expr = jackpkgsLib.onlyOnSystems ["x86_64-linux"] "aarch64-darwin" {foo = 1;};
    expected = {};
  };

  testDefaultExcludesTreefmt = {
    expr = lib.elem "node_modules/**" jackpkgsLib.defaultExcludes.treefmt;
    expected = true;
  };

  testDefaultExcludesPreCommit = {
    expr = lib.elem "/node_modules/" jackpkgsLib.defaultExcludes.preCommit;
    expected = true;
  };

  # -------------------------------------------------------------------
  # Exports that cannot be meaningfully forced here (documented, not
  # silently skipped):
  #
  # - `python.mkIsolatedUvEnvFactory` explicitly does `inherit (pkgs)
  #   lib;` (correctly bound, not the buggy pattern) and requires real
  #   `uv2nix`/`pyproject-nix`/`pyproject-build-systems` flake inputs to
  #   invoke -- unavailable at this eval level by design (see the
  #   comment at lib/default.nix:7-10). Structural check only.
  #
  # - `nodejs.mkCaptureNodeModulesCli` (lib/default.nix:194, was
  #   `{inherit lib;}`, now fixed) is a derivation whose only accessed
  #   nodejsHelpers field, `nodejs.captureNodeModules`, is a static
  #   shell-script string that never references `lib`. Forcing this
  #   derivation's `.text` therefore CANNOT distinguish the broken
  #   wiring from the fixed wiring -- the thunk is presently unreachable
  #   dead code from the aggregator's public surface. Fixed for
  #   consistency and to protect any future caller that starts using a
  #   different nodejsHelpers export from this call site, but no test
  #   here (or anywhere) currently exercises that specific line.
  # -------------------------------------------------------------------
  testMkIsolatedUvEnvFactoryIsFunction = {
    expr = builtins.isFunction jackpkgsLib.python.mkIsolatedUvEnvFactory;
    expected = true;
  };

  testMkCaptureNodeModulesCliIsDerivation = {
    expr = lib.isDerivation jackpkgsLib.nodejs.mkCaptureNodeModulesCli;
    expected = true;
  };
}
