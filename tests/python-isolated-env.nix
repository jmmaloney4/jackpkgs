# Tests for lib/python-isolated-env.nix — mkIsolatedUvEnv (ADR 044)
#
# Validates that the helper produces a correct derivation from a real
# uv.lock fixture without requiring a full build (we inspect attrs).
{
  lib,
  pkgs,
  inputs,
}: let
  mkIsolatedUvEnv = import ../lib/python-isolated-env.nix {
    inherit lib pkgs;
    inherit (inputs) uv2nix;
    pyprojectNix = inputs.pyproject-nix;
    pyprojectBuildSystems = inputs.pyproject-build-systems;
  };

  fixtureRoot = ../tests/fixtures/python-isolated-env/standard;

  example = mkIsolatedUvEnv {
    name = "python-test-isolated";
    workspaceRoot = fixtureRoot;
    python = pkgs.python313;
    mainProgram = "test-cli";
  };

  exampleWithCollisions = mkIsolatedUvEnv {
    name = "python-test-collisions";
    workspaceRoot = fixtureRoot;
    python = pkgs.python313;
    mainProgram = "test-cli";
    ignoreCollisions = ["*/site-packages/some/__init__.py"];
  };

  exampleSdist = mkIsolatedUvEnv {
    name = "python-test-sdist";
    workspaceRoot = fixtureRoot;
    python = pkgs.python313;
    sourcePreference = "sdist";
  };
in {
  # The derivation name reflects the venv name
  testName = {
    expr = example.name;
    expected = "python-test-isolated";
  };

  # mainProgram is set in meta
  testMainProgram = {
    expr = example.meta.mainProgram;
    expected = "test-cli";
  };

  # Default mainProgram is "python"
  testDefaultMainProgram = let
    e = mkIsolatedUvEnv {
      name = "python-test-default-mp";
      workspaceRoot = fixtureRoot;
      python = pkgs.python313;
    };
  in {
    expr = e.meta.mainProgram;
    expected = "python";
  };

  # ignoreCollisions is propagated to venvIgnoreCollisions
  testIgnoreCollisionsPropagated = {
    expr = exampleWithCollisions.venvIgnoreCollisions or null;
    expected = ["*/site-packages/some/__init__.py"];
  };

  # No collisions → venvIgnoreCollisions is empty
  testNoCollisionsByDefault = {
    expr = example.venvIgnoreCollisions or [];
    expected = [];
  };

  # sourcePreference = "sdist" still produces a valid derivation
  testSdistPreference = {
    expr = exampleSdist.name;
    expected = "python-test-sdist";
  };
}
