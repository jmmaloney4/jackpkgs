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
            _module.args.jackpkgsProjectRoot = null;
            jackpkgs.pre-commit = {
              treefmtPackage = pkgs.treefmt;
              nbstripoutPackage = pkgs.nbstripout;
              adr.package = pkgs.writeShellScriptBin "adr-conflict-check" "";
            };
          }
          perSystemConfig;
      }
    ];
  };

  hasInfixAll = needles: haystack: lib.all (needle: lib.hasInfix needle haystack) needles;

  # writeShellApplication produces a store-path wrapper.  Verify the entry
  # points to the expected hook binary name.
  isStoreExe = name: entry:
    lib.hasPrefix "/nix/store/" entry
    && lib.hasInfix ("/bin/" + name) entry;
in {
  testMypyEnabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.mypy.enable;
    expected = true;
  };

  testMypyPassFilenamesFalse = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.mypy.pass_filenames or true;
    expected = false;
  };

  testMypyEntrySetsPythonPath = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    # With writeShellApplication the entry is a store path wrapper;
    # shellcheck validates the script content at build time.
    expr = isStoreExe "mypy-hook" hooks.mypy.entry;
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

  testPytestDefaultUsesImportlib = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hasInfixAll ["pytest" "--import-mode=importlib"] hooks.pytest.entry;
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

  # With no dev env and no override, mypy resolves to the bare-mypy fallback,
  # which has no `ruff` executable. ruff must substitute the standalone ruff
  # package (the bug that broke the ruff pre-commit hook). pytest/numpydoc keep
  # inheriting mypy unchanged.
  testRuffFallsBackToStandaloneRuffWhenNoDevEnv = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
    pcfg = perSystemCfg.jackpkgs.pre-commit.python;
    pkgs = perSystemCfg.jackpkgs.pkgs;
  in {
    expr =
      pcfg.mypy.package
      == pkgs.mypy
      && pcfg.ruff.package == pkgs.ruff
      && pcfg.ruff.package != pcfg.mypy.package
      && pcfg.pytest.package == pkgs.mypy
      && pcfg.numpydoc.package == pkgs.mypy;
    expected = true;
  };

  # Non-regression: an explicit `mypy.package` override (a custom env that also
  # contains ruff) is still honored by ruff — the substitution only triggers for
  # the bare-mypy fallback, not for a real override. pytest/numpydoc follow too.
  testRuffHonorsMypyPackageOverride = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.python.mypy.package = dummyNodeModules;
      })
    ];
    pcfg = perSystemCfg.jackpkgs.pre-commit.python;
  in {
    expr =
      pcfg.ruff.package
      == dummyNodeModules
      && pcfg.pytest.package == dummyNodeModules
      && pcfg.numpydoc.package == dummyNodeModules;
    expected = true;
  };

  # Non-regression: when a non-editable dev-tools env is registered (the blessed
  # `jackpkgs.python.environments` path), mypy AND ruff resolve to that SAME env
  # — the shared-dev-env behavior the old `ruff.package = mypy.package` default
  # provided is preserved.
  testRuffAndMypyShareRegisteredDevEnv = let
    devEnv = dummyNodeModules;
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        topConfig = {
          jackpkgs.python.environments.devtools = {
            editable = false;
            includeGroups = true;
          };
          jackpkgs.outputs.pythonEnvironments.devtools = devEnv;
        };
      })
    ];
    pcfg = perSystemCfg.jackpkgs.pre-commit.python;
  in {
    expr = pcfg.ruff.package == devEnv && pcfg.mypy.package == devEnv;
    expected = true;
  };

  testTscUsesNodeModulesWhenConfigured = let
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.typescript.tsc = {
          nodeModules = dummyNodeModules;
          packages = ["fake/pkg"];
        };
      })
    ];
  in {
    expr = isStoreExe "tsc-hook" hooks.tsc.entry;
    expected = true;
  };

  testTscMissingNodeModulesGuidance = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.nodejs.enable = true;
      })
    ];
  in {
    expr = isStoreExe "tsc-hook-no-modules" hooks.tsc.entry;
    expected = true;
  };

  testVitestUsesNodeModulesWhenConfigured = let
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.javascript.vitest = {
          nodeModules = dummyNodeModules;
          packages = ["fake/pkg"];
        };
      })
    ];
  in {
    expr = isStoreExe "vitest-hook" hooks.vitest.entry;
    expected = true;
  };

  testVitestMissingNodeModulesGuidance = let
    hooks = getHooks [
      (mkConfigModule {
        topConfig.jackpkgs.nodejs.enable = true;
      })
    ];
  in {
    expr = isStoreExe "vitest-hook" hooks.vitest.entry;
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

  # ── ADR conflict-check hook ────────────────────────────────────────────────

  testAdrHookEnabledByDefault = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.adr-conflict-check.enable;
    expected = true;
  };

  testAdrHookPassFilenamesFalse = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hooks.adr-conflict-check.pass_filenames;
    expected = false;
  };

  testAdrHookDefaultDirectory = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hasInfixAll ["--adr-dir" "docs/internal/decisions"] hooks.adr-conflict-check.entry;
    expected = true;
  };

  testAdrHookEntryContainsBinary = let
    hooks = getHooks [(mkConfigModule {})];
  in {
    expr = hasInfixAll ["adr-conflict-check"] hooks.adr-conflict-check.entry;
    expected = true;
  };

  testAdrHookCustomDirectory = let
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.adr.directory = "records/decisions";
      })
    ];
  in {
    expr = hasInfixAll ["--adr-dir" (lib.escapeShellArg "records/decisions")] hooks.adr-conflict-check.entry;
    expected = true;
  };

  testAdrHookEscapesDirectory = let
    directory = "records/adr dir;$(touch pwned)";
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.adr.directory = directory;
      })
    ];
  in {
    expr = hasInfixAll ["--adr-dir" (lib.escapeShellArg directory)] hooks.adr-conflict-check.entry;
    expected = true;
  };

  testAdrHookDisable = let
    hooks = getHooks [
      (mkConfigModule {
        perSystemConfig.jackpkgs.pre-commit.adr.enable = false;
      })
    ];
  in {
    expr = hooks.adr-conflict-check.enable;
    expected = false;
  };
}
