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

  # Check whether the checks module options are defined, mirroring
  # the just module's: lib.hasAttrByPath ["jackpkgs" "checks"] options
  getChecksOptionDefined = modules:
    lib.hasAttrByPath ["jackpkgs" "checks"] (evalFlake modules).options;

  # Evaluate whether each lint section would be included for a given config.
  # Mirrors the predicate logic from just.nix lines 452-489:
  #   optionalLines (checksOptionsDefined && checksCfgForRecipes.<path>.enable)
  # Returns an attrset of actual booleans for better nix-unit diagnostics.
  lintSectionIncluded = modules: let
    eval = evalFlake modules;
    optionsDefined = lib.hasAttrByPath ["jackpkgs" "checks"] eval.options;
    cfg = lib.attrByPath ["jackpkgs" "checks"] {} eval.config;
  in {
    ruff = optionsDefined && (cfg.python.ruff.enable or false);
    mypy = optionsDefined && (cfg.python.mypy.enable or false);
    tsc = optionsDefined && (cfg.typescript.tsc.enable or false);
    biome = optionsDefined && (lib.attrByPath ["biome" "lint" "enable"] false cfg);
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
  # --- checksOptionsDefined gate ---

  testChecksOptionsDefinedWithChecksModule = {
    expr = getChecksOptionDefined [(mkConfigModule {})];
    expected = true;
  };

  # --- Lint recipe: ruff section ---

  testLintRuffIncludedWhenEnabled = {
    expr = lintSectionIncluded [(mkConfigModule {})];
    expected = {ruff = true; mypy = true; tsc = false; biome = false;};
  };

  testLintRuffExcludedWhenDisabled = {
    expr = lintSectionIncluded [
      (mkConfigModule {extraChecks.python.ruff.enable = false;})
    ];
    expected = {ruff = false; mypy = true; tsc = false; biome = false;};
  };

  # --- Lint recipe: mypy section ---

  testLintMypyExcludedWhenDisabled = {
    expr = lintSectionIncluded [
      (mkConfigModule {extraChecks.python.mypy.enable = false;})
    ];
    expected = {ruff = true; mypy = false; tsc = false; biome = false;};
  };

  # --- Lint recipe: tsc section ---

  testLintTscIncludedWhenNodejsEnabled = {
    expr = lintSectionIncluded [(mkConfigModule {withNodejs = true;})];
    expected = {ruff = true; mypy = true; tsc = true; biome = false;};
  };

  testLintTscExcludedWhenNodejsDisabled = {
    expr = lintSectionIncluded [(mkConfigModule {withNodejs = false;})];
    expected = {ruff = true; mypy = true; tsc = false; biome = false;};
  };

  testLintTscExplicitDisableOverridesNodejsEnable = {
    expr = lintSectionIncluded [
      (mkConfigModule {
        withNodejs = true;
        extraChecks.typescript.tsc.enable = false;
      })
    ];
    expected = {ruff = true; mypy = true; tsc = false; biome = false;};
  };

  testLintTscDefaultsWithoutNodejs = {
    expr = (lintSectionIncluded [(mkConfigModule {withNodejs = false;})]).tsc;
    expected = false;
  };

  # --- Lint recipe: biome section ---

  testLintBiomeExcludedByDefault = {
    # Even with nodejs enabled (which enables tsc), biome stays false
    expr = (lintSectionIncluded [(mkConfigModule {withNodejs = true;})]).biome;
    expected = false;
  };

  # --- Lint recipe: all enabled together ---

  testLintAllToolsEnabledTogether = {
    expr = lintSectionIncluded [
      (mkConfigModule {
        withNodejs = true;
        extraChecks.biome.lint.enable = true;
      })
    ];
    expected = {ruff = true; mypy = true; tsc = true; biome = true;};
  };

  # --- Lint recipe: all disabled ---

  testLintAllToolsDisabled = {
    expr = lintSectionIncluded [
      (mkConfigModule {
        extraChecks = {
          python.ruff.enable = false;
          python.mypy.enable = false;
        };
      })
    ];
    expected = {ruff = false; mypy = false; tsc = false; biome = false;};
  };

  # --- Lint recipe: partial enables ---

  testLintOnlyTscEnabled = {
    expr = lintSectionIncluded [
      (mkConfigModule {
        withNodejs = true;
        extraChecks = {
          python.ruff.enable = false;
          python.mypy.enable = false;
        };
      })
    ];
    expected = {ruff = false; mypy = false; tsc = true; biome = false;};
  };

  testLintOnlyRuffEnabled = {
    expr = lintSectionIncluded [
      (mkConfigModule {extraChecks.python.mypy.enable = false;})
    ];
    expected = {ruff = true; mypy = false; tsc = false; biome = false;};
  };
}
