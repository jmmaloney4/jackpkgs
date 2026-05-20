{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  checksModule = import ../modules/flake-parts/checks.nix {jackpkgsInputs = inputs;};
  justModule = import ../modules/flake-parts/just.nix {jackpkgsInputs = inputs;};

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

      pulumi = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        backendUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        secretsProvider = mkOption {
          type = types.str;
          default = "";
        };
        stacks = mkOption {
          type = types.listOf types.unspecified;
          default = [];
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
        pulumiJustfile = mkOption {
          type = types.lines;
          default = "";
        };
      };
    };
  };

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [optionsModule libModule pkgsModule checksModule] ++ modules ++ [justModule];
    };

  # Evaluate whether each test recipe section would be included for a given config.
  # Mirrors the predicate logic from just.nix:
  #   optionalLines (checksOptionsDefined && checksCfgForRecipes.python.pytest.enable)
  #   optionalLines (checksOptionsDefined && checksCfgForRecipes.vitest.enable)
  testSectionIncluded = modules: let
    eval = evalFlake modules;
    optionsDefined = lib.hasAttrByPath ["jackpkgs" "checks"] eval.options;
    cfg = lib.attrByPath ["jackpkgs" "checks"] {} eval.config;
  in {
    pytest = optionsDefined && (cfg.python.pytest.enable or false);
    vitest = optionsDefined && (cfg.vitest.enable or false);
  };

  mkConfigModule = {
    extraChecks ? {},
    withNodejs ? false,
  }: {
    _module.check = false;
    jackpkgs.pulumi.secretsProvider = "unused";
    jackpkgs.checks =
      lib.recursiveUpdate
      {
        python = {
          enable = true;
          pytest.enable = true;
          mypy.enable = true;
          ruff.enable = true;
        };
      }
      extraChecks;

    jackpkgs.outputs = {
      pythonEnvironments = {};
      pythonDefaultEnv = null;
      pulumiJustfile = "";
    };

    jackpkgs.nodejs.enable = withNodejs;

    perSystem = {_module.args.jackpkgsProjectRoot = null;};
  };
in {
  # --- test recipe: pytest section ---

  testPytestIncludedWhenEnabled = {
    expr = testSectionIncluded [(mkConfigModule {})];
    expected = {
      pytest = true;
      vitest = false;
    };
  };

  testPytestExcludedWhenDisabled = {
    expr = testSectionIncluded [
      (mkConfigModule {extraChecks.python.pytest.enable = false;})
    ];
    expected = {
      pytest = false;
      vitest = false;
    };
  };

  # --- test recipe: vitest section ---

  testVitestDefaultsToNodejsEnable = {
    expr = testSectionIncluded [(mkConfigModule {withNodejs = true;})];
    expected = {
      pytest = true;
      vitest = true;
    };
  };

  testVitestExcludedWhenNodejsDisabled = {
    expr = testSectionIncluded [(mkConfigModule {withNodejs = false;})];
    expected = {
      pytest = true;
      vitest = false;
    };
  };

  testVitestExplicitDisableOverridesNodejsEnable = {
    expr = testSectionIncluded [
      (mkConfigModule {
        withNodejs = true;
        extraChecks.vitest.enable = false;
      })
    ];
    expected = {
      pytest = true;
      vitest = false;
    };
  };

  # --- test recipe: both disabled ---

  testBothToolsDisabled = {
    expr = testSectionIncluded [
      (mkConfigModule {
        extraChecks = {
          python.pytest.enable = false;
        };
      })
    ];
    expected = {
      pytest = false;
      vitest = false;
    };
  };

  # --- test recipe: partial enables ---

  testOnlyVitestEnabled = {
    expr = testSectionIncluded [
      (mkConfigModule {
        withNodejs = true;
        extraChecks.python.pytest.enable = false;
      })
    ];
    expected = {
      pytest = false;
      vitest = true;
    };
  };
}
