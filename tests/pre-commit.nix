{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  checksModule = import ../modules/flake-parts/checks.nix {jackpkgsInputs = inputs;};
  preCommitModule = import ../modules/flake-parts/pre-commit.nix {jackpkgsInputs = inputs;};

  # Stubs module: declares only options that aren't covered by the real modules
  # but are needed to evaluate cleanly in the test harness.
  optionsModule = {lib, ...}: let
    inherit (lib) mkOption types;
  in {
    options.jackpkgs = {
      python = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };

        environments = mkOption {
          type = types.attrsOf (types.submodule {
            options = {
              editable = mkOption {
                type = types.bool;
                default = false;
              };
              includeGroups = mkOption {
                type = types.nullOr types.bool;
                default = null;
              };
            };
          });
          default = {};
        };
      };

      nodejs.enable = mkOption {
        type = types.bool;
        default = false;
      };

      pulumi.enable = mkOption {
        type = types.bool;
        default = false;
      };

      outputs = {
        pythonEnvironments = mkOption {
          type = types.attrsOf types.unspecified;
          default = {};
        };
        pythonDefaultEnv = mkOption {
          type = types.nullOr types.package;
          default = null;
        };
        nodeModules = mkOption {
          type = types.nullOr types.package;
          default = null;
        };
      };
    };
  };

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      # Import real checksModule so jackpkgs.checks options are declared and
      # pre-commit.nix can read checksCfg = config.jackpkgs.checks correctly.
      imports = [optionsModule libModule pkgsModule checksModule] ++ modules ++ [preCommitModule];
    };

  evalFlakeWithoutChecks = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [optionsModule libModule pkgsModule] ++ modules ++ [preCommitModule];
    };

  getPerSystemCfg = modules: (evalFlake modules).config.perSystem system;
  getPerSystemCfgWithoutChecks = modules: (evalFlakeWithoutChecks modules).config.perSystem system;

  getHooks = modules: (getPerSystemCfg modules).pre-commit.settings.hooks;
  getHooksWithoutChecks = modules: (getPerSystemCfgWithoutChecks modules).pre-commit.settings.hooks;

  dummyNodeModules = builtins.derivation {
    name = "dummy-node-modules";
    inherit system;
    builder = "/bin/sh";
    args = ["-c" "mkdir -p $out/node_modules/.bin"];
  };

  # mkConfigModule builds a test module.
  # - topConfig: top-level jackpkgs.checks overrides (attrset merged at module top level)
  # - perSystemConfig: per-system jackpkgs.pre-commit overrides (merged inside perSystem)
  mkConfigModule = {
    topConfig ? {},
    perSystemConfig ? {},
  }: {
    imports = [
      {
        _module.check = false;
        jackpkgs.pre-commit.enable = true;
        jackpkgs.outputs = {
          pythonEnvironments = {};
          pythonDefaultEnv = null;
          nodeModules = null;
        };
      }
      topConfig
      {
        perSystem = {pkgs, ...}:
          lib.recursiveUpdate
          {
            jackpkgs.pre-commit = {
              treefmtPackage = pkgs.treefmt;
              nbstripoutPackage = pkgs.nbstripout;
            };
          }
          perSystemConfig;
      }
    ];
  };

  hasInfixAll = needles: haystack: lib.all (needle: lib.hasInfix needle haystack) needles;
in {
  testMypyEnabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.mypy.enable;
    expected = true;
  };

  testRuffEnabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.ruff.enable;
    expected = true;
  };

  testPytestEnabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.pytest.enable;
    expected = true;
  };

  testNumpydocDisabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.numpydoc.enable;
    expected = false;
  };

  testTscEnabledWhenNodejsEnabled = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.nodejs.enable = true;
      })
    ];
  in {
    expr = hooks.tsc.enable;
    expected = true;
  };

  testTscDisabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.tsc.enable;
    expected = false;
  };

  testVitestEnabledWhenNodejsEnabled = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.nodejs.enable = true;
      })
    ];
  in {
    expr = hooks.vitest.enable;
    expected = true;
  };

  testVitestDisabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.vitest.enable;
    expected = false;
  };

  testPytestPrePushStage = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.pytest.stages == ["pre-push"];
    expected = true;
  };

  testVitestPrePushStage = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.vitest.stages == ["pre-push"];
    expected = true;
  };

  testRuffExtraArgsAppearInEntry = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.checks.python.ruff.extraArgs = ["--fix" "--unsafe-fixes"];
      })
    ];
  in {
    expr = hasInfixAll ["ruff" "check" "--fix" "--unsafe-fixes"] hooks.ruff.entry;
    expected = true;
  };

  testNumpydocExtraArgsAppearInEntry = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.checks.python.numpydoc = {
          enable = true;
          extraArgs = ["--checks" "all" "--exclude" "GL08"];
        };
      })
    ];
  in {
    expr =
      hasInfixAll [
        "python -m numpydoc.hooks.validate_docstrings"
        "--checks"
        "all"
        "--exclude"
        "GL08"
        " ."
      ]
      hooks.numpydoc.entry;
    expected = true;
  };

  testPreCommitRequiresChecksModule = {
    expr = (builtins.tryEval ((getHooksWithoutChecks [(mkConfigModule {})]).mypy.enable)).success;
    expected = false;
  };

  testRuffPytestNumpydocDefaultToMypyPackage = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.python.mypy.package = dummyNodeModules;
      })
    ];
    pcfg = perSystemCfg.jackpkgs.pre-commit.python;
  in {
    expr =
      pcfg.ruff.package == pcfg.mypy.package
      && pcfg.pytest.package == pcfg.mypy.package
      && pcfg.numpydoc.package == pcfg.mypy.package;
    expected = true;
  };

  testTscUsesNodeModulesWhenConfigured = let
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.typescript.tsc.nodeModules = dummyNodeModules;
      })
    ];
  in {
    expr = hasInfixAll ["nm_store=" "ln -sfn \"$nm_root\" node_modules" "tsc" "--noEmit"] hooks.tsc.entry;
    expected = true;
  };

  testTscMissingNodeModulesGuidance = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.nodejs.enable = true;
      })
    ];
  in {
    expr =
      hasInfixAll [
        "ERROR: node_modules not found for TypeScript pre-commit hook."
        "jackpkgs.nodejs.enable = true;"
        "jackpkgs.pre-commit.typescript.tsc.nodeModules"
        "jackpkgs.checks.typescript.tsc.enable = false;"
      ]
      hooks.tsc.entry;
    expected = true;
  };

  testVitestUsesNodeModulesWhenConfigured = let
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.javascript.vitest.nodeModules = dummyNodeModules;
      })
    ];
  in {
    expr = hasInfixAll ["nm_store=" "node_modules/.bin/vitest" "vitest" "run"] hooks.vitest.entry;
    expected = true;
  };

  testVitestMissingNodeModulesGuidance = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.nodejs.enable = true;
      })
    ];
  in {
    expr =
      hasInfixAll [
        "ERROR: vitest binary not found for pre-commit hook."
        "jackpkgs.nodejs.enable = true;"
        "jackpkgs.pre-commit.javascript.vitest.nodeModules"
        "jackpkgs.checks.vitest.enable = false;"
      ]
      hooks.vitest.entry;
    expected = true;
  };

  testDisableMypyHook = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.checks.python.mypy.enable = false;
      })
    ];
  in {
    expr = hooks.mypy.enable;
    expected = false;
  };

  testDisableRuffHook = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.checks.python.ruff.enable = false;
      })
    ];
  in {
    expr = hooks.ruff.enable;
    expected = false;
  };
}
