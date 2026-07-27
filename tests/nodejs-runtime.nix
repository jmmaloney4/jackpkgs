# Behavioural tests for jackpkgsLib.nodejs.mkWorkspaceRuntime.
#
# The string-level assertions in tests/checks.nix freeze the *shape* of the
# generated script; these run it against a synthetic workspace so the linking
# semantics are checked directly.  Issue #358 (a `ln -sfn` that nested into an
# existing real `node_modules` instead of replacing it) was invisible to the
# string tests because the emitted script looked exactly right.
{
  lib,
  pkgs,
}: let
  helpers = import ../lib/nodejs-helpers.nix {inherit lib;};

  workspaceRoot = ./fixtures/nodejs-runtime/workspace;
  packages = ["packages/app" "packages/lib"];

  # Stands in for the derivation built by jackpkgs.nodejs: root dependencies
  # under $out/node_modules plus a package-local tree under
  # $out/<pkg>/node_modules (the output contract from ADR-028).
  nodeModules = pkgs.runCommand "test-fake-node-modules" {} ''
    mkdir -p "$out/node_modules/left-pad" "$out/node_modules/@scope/util" "$out/node_modules/.bin"
    echo root-dep > "$out/node_modules/left-pad/marker"
    echo scoped-dep > "$out/node_modules/@scope/util/marker"

    mkdir -p "$out/packages/app/node_modules/@pulumi/kubernetes"
    echo pkg-local-dep > "$out/packages/app/node_modules/@pulumi/kubernetes/marker"
  '';

  runtime = helpers.nodejs.mkWorkspaceRuntime {
    inherit nodeModules workspaceRoot packages;
  };

  # Every case runs the same runtime script over a writable copy of the
  # workspace fixture; only the pre-existing on-disk state differs.
  mkRuntimeTest = {
    name,
    setup ? "",
    runtimeInvocations ? 1,
    assertions,
  }:
    pkgs.runCommand "test-node-workspace-runtime-${name}" {} ''
      mkdir -p work
      cp -R ${workspaceRoot}/. work/
      chmod -R u+w work
      cd work

      ${setup}

      ${lib.concatStringsSep "\n" (lib.genList (_: runtime) runtimeInvocations)}

      ${assertions}

      echo "✅ mkWorkspaceRuntime: ${name}"
      touch "$out"
    '';

  # Assertions that must hold after any successful run, whatever the starting
  # state was.
  commonAssertions = ''
    # Package-local dependencies come from the pinned tree, not from a nested
    # node_modules/node_modules.
    test -L packages/app/node_modules
    test ! -e packages/app/node_modules/node_modules
    grep -qx pkg-local-dep packages/app/node_modules/@pulumi/kubernetes/marker

    # Root dependencies, scoped and unscoped.
    test -L node_modules/left-pad
    grep -qx root-dep node_modules/left-pad/marker
    test -L node_modules/@scope/util
    grep -qx scoped-dep node_modules/@scope/util/marker

    # Workspace packages resolve to the checkout, by package.json name.
    test -L node_modules/@test/app
    test -f node_modules/@test/app/package.json
    test -L node_modules/lib
    test -f node_modules/lib/package.json
  '';
in {
  # The issue #358 regression: `pnpm install` leaves real per-package
  # node_modules directories behind, and `ln -sfn` linked *into* them.
  testReplacesRealNodeModulesDirectories = mkRuntimeTest {
    name = "replaces-real-directories";
    setup = ''
      # What pnpm leaves in a working copy, including a stale link into a
      # deleted worktree — the shape that produced the confusing
      # "Cannot find module '@pulumi/kubernetes'" failure.
      mkdir -p packages/app/node_modules
      ln -s /nonexistent/deleted-worktree/pulumi packages/app/node_modules/@pulumi
      mkdir -p node_modules/left-pad
      echo stale > node_modules/left-pad/marker
    '';
    assertions = ''
      ${commonAssertions}

      # The pre-existing directory was replaced, not linked into: the stale
      # @pulumi link is gone and the destination points at the pinned tree.
      test "$(readlink packages/app/node_modules)" = "${nodeModules}/packages/app/node_modules"
      test "$(readlink node_modules/left-pad)" = "${nodeModules}/node_modules/left-pad"
    '';
  };

  # A second run must be a no-op rather than re-nesting under the symlink it
  # created on the first pass.
  testIdempotentAcrossRuns = mkRuntimeTest {
    name = "idempotent";
    setup = ''
      mkdir -p packages/app/node_modules
    '';
    runtimeInvocations = 2;
    assertions = commonAssertions;
  };

  # A scope directory left over as a symlink into the read-only store would
  # make every link inside it fail with EACCES.
  testReplacesSymlinkedScopeDirectory = mkRuntimeTest {
    name = "symlinked-scope-dir";
    setup = ''
      mkdir -p node_modules
      ln -s ${nodeModules}/node_modules/@scope node_modules/@scope
    '';
    assertions = ''
      ${commonAssertions}

      test ! -L node_modules/@scope
      test -d node_modules/@scope
    '';
  };

  # The clean-checkout path stays green.
  testFreshCheckout = mkRuntimeTest {
    name = "fresh-checkout";
    assertions = commonAssertions;
  };

  # pre-commit.nix embeds the runtime in writeShellApplication wrappers, so the
  # emitted shell has to survive `set -euo pipefail` plus shellcheck.
  testShellcheckClean = pkgs.writeShellApplication {
    name = "test-node-workspace-runtime-shellcheck";
    text = runtime;
  };
}
