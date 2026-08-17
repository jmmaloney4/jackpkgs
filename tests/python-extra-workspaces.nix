# Tests for jackpkgs.python.extraWorkspaces (ADR 048) and the
# lib/python-workspace-scope.nix helper it is built on.
#
# The module-level tests evaluate the real python flake-parts module against
# tiny dependency-free uv workspace fixtures (tests/fixtures/
# python-extra-workspaces/{primary,secondary,missing-lock}; lockfiles
# generated with `uv lock`). nix-unit is eval-only, so assertions inspect
# derivation attributes (name, NIX_PYPROJECT_DEPS) rather than building.
{
  lib,
  pkgs,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  pythonModule = import ../modules/flake-parts/python.nix {jackpkgsInputs = inputs;};

  fixturesRoot = ../tests/fixtures/python-extra-workspaces;
  primaryRoot = fixturesRoot + "/primary";
  secondaryRoot = fixturesRoot + "/secondary";
  missingLockRoot = fixturesRoot + "/missing-lock";

  # Overlay that visibly rewrites the secondary workspace's only package.
  # The overridden derivation name lands in the env's NIX_PYPROJECT_DEPS
  # store-path list, making the override observable from the outside.
  markerOverlay = _final: prev: {
    fixture-secondary = prev.fixture-secondary.overrideAttrs (_old: {
      name = "fixture-secondary-overridden-9.9.9";
    });
  };

  baseModule = {_module.check = false;};

  # The python module wires jackpkgs.shell.{inputsFrom,packages}, normally
  # declared by the shell module; declare lightweight stand-ins here.
  mockShellModule = {
    perSystem = {lib, ...}: {
      options.jackpkgs.shell = {
        inputsFrom = lib.mkOption {
          type = lib.types.listOf lib.types.unspecified;
          default = [];
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.unspecified;
          default = [];
        };
      };
    };
  };

  projectRootModule = {
    perSystem = {...}: {
      _module.args.jackpkgsProjectRoot = primaryRoot;
    };
  };

  # Evaluate the python module with a primary workspace plus arbitrary extra
  # jackpkgs.python config (an attrset merged into jackpkgs.python).
  evalPython = pythonConfig: let
    eval = flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [baseModule libModule pkgsModule pythonModule mockShellModule projectRootModule];
      jackpkgs.python =
        {
          enable = true;
          workspaceRoot = primaryRoot;
          environments.default = {
            name = "fixture-primary-env";
          };
        }
        // pythonConfig;
    };
  in
    eval.config.perSystem system;

  getEnvs = perSystemCfg: perSystemCfg.jackpkgs.outputs.pythonEnvironments;

  withSecondary = evalPython {
    extraWorkspaces.secondary = {
      workspaceRoot = secondaryRoot;
      extraOverlays = [markerOverlay];
      environments.secondary = {
        name = "fixture-secondary-env";
      };
    };
  };

  # Direct helper-level scope (same entry point the module uses), so overlay
  # application is also asserted on the package set itself.
  mkWorkspaceScope = import ../lib/python-workspace-scope.nix {
    inherit lib;
    inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
  };

  scope = mkWorkspaceScope {
    inherit pkgs;
    python = pkgs.python313;
    workspaceRoot = secondaryRoot;
    sourcePreference = "wheel";
    extraOverlays = [markerOverlay];
    label = "test-scope";
  };
in {
  # ---------------------------------------------------------
  # Primary path still works with extraWorkspaces present
  # ---------------------------------------------------------

  testPrimaryEnvStillPresent = {
    expr = (getEnvs withSecondary).default.name;
    expected = "fixture-primary-env";
  };

  testPrimaryEnvResolvesItsWorkspace = {
    # Forces the full primary chain (workspace load, overlays, spec
    # resolution) — the fixture package's store path must appear in the env.
    expr = lib.hasInfix "fixture-primary" (getEnvs withSecondary).default.NIX_PYPROJECT_DEPS;
    expected = true;
  };

  # ---------------------------------------------------------
  # Secondary environments in outputs
  # ---------------------------------------------------------

  testSecondaryEnvInPythonEnvironments = {
    expr = (getEnvs withSecondary).secondary.name;
    expected = "fixture-secondary-env";
  };

  testSecondaryEnvPublishedAsPackage = {
    expr = withSecondary.packages ? "fixture-secondary-env";
    expected = true;
  };

  testSecondaryEnvNotDefaultEnv = {
    # pythonDefaultEnv keys off the PRIMARY `default` env only.
    expr = withSecondary.jackpkgs.outputs.pythonDefaultEnv.name;
    expected = "fixture-primary-env";
  };

  # ---------------------------------------------------------
  # extraOverlays application
  # ---------------------------------------------------------

  testExtraOverlayVisibleInSecondaryEnv = {
    expr = lib.hasInfix "fixture-secondary-overridden-9.9.9" (getEnvs withSecondary).secondary.NIX_PYPROJECT_DEPS;
    expected = true;
  };

  testScopeOverlayVisibleOnPythonSet = {
    expr = scope.pythonSet.fixture-secondary.name;
    expected = "fixture-secondary-overridden-9.9.9";
  };

  testScopeDefaultSpecCoversFixture = {
    expr = scope.defaultSpec;
    expected = {fixture-secondary = [];};
  };

  # ---------------------------------------------------------
  # Collision checks
  # ---------------------------------------------------------

  testDuplicateEnvNameThrows = let
    perSystemCfg = evalPython {
      extraWorkspaces.secondary = {
        workspaceRoot = secondaryRoot;
        environments.clashing = {
          # Same package name as the primary `default` env.
          name = "fixture-primary-env";
        };
      };
    };
  in {
    expr = builtins.attrNames (getEnvs perSystemCfg);
    expectedError.type = "ThrownError";
    expectedError.msg = "duplicate environment package names";
  };

  testDuplicateEnvKeyThrows = let
    perSystemCfg = evalPython {
      extraWorkspaces.secondary = {
        workspaceRoot = secondaryRoot;
        environments.default = {
          # Unique package name, but the attribute key collides with the
          # primary `default` env in the flat pythonEnvironments map.
          name = "fixture-secondary-env";
        };
      };
    };
  in {
    expr = builtins.attrNames (getEnvs perSystemCfg);
    expectedError.type = "ThrownError";
    expectedError.msg = "duplicate environment attribute keys";
  };

  # ---------------------------------------------------------
  # Fail-fast asserts carry the workspace key
  # ---------------------------------------------------------

  testMissingUvLockThrowsWithWorkspaceLabel = let
    perSystemCfg = evalPython {
      extraWorkspaces.broken = {
        workspaceRoot = missingLockRoot;
        environments.broken-env = {
          name = "fixture-broken-env";
        };
      };
    };
  in {
    expr = (getEnvs perSystemCfg).broken-env.NIX_PYPROJECT_DEPS;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs.python.extraWorkspaces.broken: uv.lock not found";
  };
}
