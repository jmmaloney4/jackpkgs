{
  lib,
  inputs,
}: let
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  jackpkgsLib = (libModule {inherit lib;})._module.args.jackpkgsLib;

  brokenLockfile = builtins.fromJSON (
    builtins.readFile ./fixtures/checks/npm-lockfile/workspace-broken/package-lock.json
  );
  fixedLockfile = builtins.fromJSON (
    builtins.readFile ./fixtures/checks/npm-lockfile/workspace-fixed/package-lock.json
  );
  noWorkspaceLockfile = builtins.fromJSON (
    builtins.readFile ./fixtures/checks/npm-lockfile/no-workspace/package-lock.json
  );
  v2Lockfile = builtins.fromJSON (
    builtins.readFile ./fixtures/checks/npm-lockfile/v2-lockfile/package-lock.json
  );
in {
  testBrokenWorkspaceLockfileDetected = let
    result = jackpkgsLib.lockfileIsCacheable brokenLockfile;
  in {
    expr = result;
    expected = {
      valid = false;
      uncacheablePackages = ["packages/lib/node_modules/lodash"];
      skipped = false;
    };
  };

  testFixedWorkspaceLockfilePasses = let
    result = jackpkgsLib.lockfileIsCacheable fixedLockfile;
  in {
    expr = result;
    expected = {
      valid = true;
      uncacheablePackages = [];
      skipped = false;
    };
  };

  testNoWorkspaceLockfilePasses = let
    result = jackpkgsLib.lockfileIsCacheable noWorkspaceLockfile;
  in {
    expr = result.valid && result.uncacheablePackages == [] && result.skipped == false;
    expected = true;
  };

  testV2LockfileSkipped = let
    result = jackpkgsLib.lockfileIsCacheable v2Lockfile;
  in {
    expr = result;
    expected = {
      valid = true;
      uncacheablePackages = [];
      skipped = true;
    };
  };

  testMultipleMissingPackagesReported = let
    result = jackpkgsLib.lockfileIsCacheable (builtins.fromJSON ''
      {
        "lockfileVersion": 3,
        "packages": {
          "": {"name": "test"},
          "node_modules/a": {"version": "1.0.0"},
          "node_modules/b": {"version": "2.0.0"},
          "node_modules/c": {
            "version": "3.0.0",
            "resolved": "https://registry.npmjs.org/c/-/c-3.0.0.tgz",
            "integrity": "sha512-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=="
          }
        }
      }
    '');
  in {
    expr = builtins.length result.uncacheablePackages;
    expected = 2;
  };
}
