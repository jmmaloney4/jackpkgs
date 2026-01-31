# Tests that validate nixpkgs' importNpmLock behavior with various lockfile fixtures
{
  inputs,
  lib,
}: let
  pkgs = import inputs.nixpkgs {system = "x86_64-linux";};

  fixtures = {
    broken = ./fixtures/checks/npm-lockfile/workspace-broken;
    fixed = ./fixtures/checks/npm-lockfile/workspace-fixed;
    simpleNpm = ./fixtures/integration/simple-npm;
    pulumiMonorepo = ./fixtures/integration/pulumi-monorepo;
  };
in {
  # Test 1: importNpmLock accepts simple npm lockfiles
  testSimpleNpmLockImportable = let
    result = pkgs.importNpmLock {npmRoot = fixtures.simpleNpm;};
  in {
    expr = result ? "type";
    expected = true;
  };

  # Test 2: importNpmLock accepts Pulumi monorepo lockfiles
  testPulumiMonorepoLockImportable = let
    result = pkgs.importNpmLock {npmRoot = fixtures.pulumiMonorepo;};
  in {
    expr = result ? "type";
    expected = true;
  };

  # Test 3: importNpmLock accepts fixed workspace lockfiles
  testFixedWorkspaceLockImportable = let
    result = pkgs.importNpmLock {npmRoot = fixtures.fixed;};
  in {
    expr = result ? "type";
    expected = true;
  };

  # Test 4: importNpmLock accepts broken workspace lockfiles (nixpkgs doesn't validate, npm ci will fail)
  testBrokenWorkspaceLockImportable = let
    result = pkgs.importNpmLock {npmRoot = fixtures.broken;};
  in {
    expr = result ? "type";
    expected = true;
  };

  # Test 5: Simple npm and Pulumi monorepo both generate derivations
  testBothFixturesGenerateDerivations = let
    simple = pkgs.importNpmLock {npmRoot = fixtures.simpleNpm;};
    pulumi = pkgs.importNpmLock {npmRoot = fixtures.pulumiMonorepo;};
  in {
    expr = simple ? "type" && pulumi ? "type";
    expected = true;
  };
}
