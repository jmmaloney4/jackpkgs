{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  preCommitModule = import ../modules/flake-parts/pre-commit.nix {jackpkgsInputs = inputs;};

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
      imports = [optionsModule libModule pkgsModule] ++ modules ++ [preCommitModule];
    };

  getPerSystemCfg = modules: (evalFlake modules).config.perSystem system;

  getHooks = modules: (getPerSystemCfg modules).pre-commit.settings.hooks;

  dummyNodeModules = builtins.derivation {
    name = "dummy-node-modules";
    inherit system;
    builder = "/bin/sh";
    args = ["-c" "mkdir -p $out/node_modules/.bin"];
  };

  mkConfigModule = {extraConfig ? {}}: {
    _module.check = false;
    jackpkgs.pre-commit.enable = true;
    jackpkgs.outputs = {
      pythonEnvironments = {};
      pythonDefaultEnv = null;
      nodeModules = null;
    };
    perSystem = {pkgs, ...}:
      lib.recursiveUpdate
      {
        jackpkgs = {
          pre-commit = {
            treefmtPackage = pkgs.treefmt;
            nbstripoutPackage = pkgs.nbstripout;

            python = {};
          };
        };
      }
      extraConfig;
  };

  hasInfixAll = needles: haystack: lib.all (needle: lib.hasInfix needle haystack) needles;
in {
  testMypyEnabledByDefault = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.mypy.enable;
    expected = true;
  };

  testRuffEnabledByDefault = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.ruff.enable;
    expected = true;
  };

  testPytestEnabledByDefault = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.pytest.enable;
    expected = true;
  };

  testNumpydocDisabledByDefault = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.numpydoc.enable;
    expected = false;
  };

  testTscEnabledByDefault = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.tsc.enable;
    expected = true;
  };

  testVitestEnabledByDefault = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.vitest.enable;
    expected = true;
  };

  testPytestPrePushStage = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.pytest.stages == ["pre-push"];
    expected = true;
  };

  testVitestPrePushStage = let
    hooks = getHooks [
      (mkConfigModule {})
    ];
  in {
    expr = hooks.vitest.stages == ["pre-push"];
    expected = true;
  };

  testRuffExtraArgsAppearInEntry = let
    hooks = getHooks [
      (mkConfigModule {
        extraConfig.jackpkgs.pre-commit.python.ruff.extraArgs = ["--fix" "--unsafe-fixes"];
      })
    ];
  in {
    expr = hasInfixAll ["ruff" "check" "--fix" "--unsafe-fixes"] hooks.ruff.entry;
    expected = true;
  };

  testNumpydocExtraArgsAppearInEntry = let
    hooks = getHooks [
      (mkConfigModule {
        extraConfig.jackpkgs.pre-commit.python.numpydoc = {
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
      ]
      hooks.numpydoc.entry;
    expected = true;
  };

  testRuffPytestNumpydocDefaultToMypyPackage = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        extraConfig.jackpkgs.pre-commit = {
          python = {
            mypy.package = dummyNodeModules;
          };
        };
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
        extraConfig.jackpkgs.pre-commit.typescript.tsc.nodeModules = dummyNodeModules;
      })
    ];
  in {
    expr = hasInfixAll ["nm_store=" "ln -sfn \"$nm_root\" node_modules" "tsc" "--noEmit"] hooks.tsc.entry;
    expected = true;
  };

  testVitestUsesNodeModulesWhenConfigured = let
    hooks = getHooks [
      (mkConfigModule {
        extraConfig.jackpkgs.pre-commit.javascript.vitest.nodeModules = dummyNodeModules;
      })
    ];
  in {
    expr = hasInfixAll ["nm_store=" "node_modules/.bin/vitest" "vitest" "run"] hooks.vitest.entry;
    expected = true;
  };

  testDisableMypyHook = let
    hooks = getHooks [
      (mkConfigModule {
        extraConfig.jackpkgs.pre-commit.python.mypy.enable = false;
      })
    ];
  in {
    expr = hooks.mypy.enable;
    expected = false;
  };

  testDisableRuffHook = let
    hooks = getHooks [
      (mkConfigModule {
        extraConfig.jackpkgs.pre-commit.python.ruff.enable = false;
      })
    ];
  in {
    expr = hooks.ruff.enable;
    expected = false;
  };
}
