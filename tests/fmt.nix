{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  fmtModule = import ../modules/flake-parts/fmt.nix {jackpkgsInputs = inputs;};
  projectRootModule = import ../modules/flake-parts/project-root.nix {jackpkgsInputs = inputs;};

  baseModule = {
    _module.check = false;
  };

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [baseModule fmtModule projectRootModule] ++ modules;
    };

  getTreefmtConfig = modules: let
    eval = evalFlake modules;
    perSystemCfg = eval.config.perSystem system;
  in
    perSystemCfg.treefmt;

  getSettingsFormatter = modules:
    (getTreefmtConfig modules).settings.formatter or {};

  hasInfixAll = needles: haystack: lib.all (n: lib.hasInfix n haystack) needles;
in {
  # Test that nbqa formatter is not created when disabled (default)
  testNbqaDisabledByDefault = let
    formatters = getSettingsFormatter [{}];
  in {
    expr = !(lib.hasAttr "python-notebook-format" formatters);
    expected = true;
  };

  # Test that nbqa formatter is created when enabled (format only; lint is in checks.nix)
  testNbqaEnabledCreatesFormatFormatter = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
  in {
    expr = lib.hasAttr "python-notebook-format" formatters;
    expected = true;
  };

  # Test that no lint formatter is created (lint moved to checks.nix)
  testNbqaNoLintFormatter = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
  in {
    expr = !(lib.hasAttr "python-notebook-lint" formatters);
    expected = true;
  };

  # Test that formatter has correct command
  testNbqaFormatterCommand = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
  in {
    expr = lib.hasInfix "nbqa" formatters.python-notebook-format.command;
    expected = true;
  };

  # Test default includes
  testNbqaDefaultIncludes = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
  in {
    expr = formatters.python-notebook-format.includes;
    expected = ["*.ipynb" "*.qmd"];
  };

  # Test custom includes
  testNbqaCustomIncludes = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa = {
            enable = true;
            includes = ["*.ipynb"];
          };
        };
      }
    ];
  in {
    expr = formatters.python-notebook-format.includes;
    expected = ["*.ipynb"];
  };

  # Test ruff format options are passed
  testNbqaRuffFormatOptions = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa = {
            enable = true;
            ruffFormatOptions = ["--line-length=88" "--target-version=py312"];
          };
        };
      }
    ];
    options = formatters.python-notebook-format.options;
    optionsStr = lib.concatStringsSep " " options;
  in {
    expr = lib.hasInfix "--line-length=88" optionsStr && lib.hasInfix "--target-version=py312" optionsStr;
    expected = true;
  };

  # Test format options include shell mode flag and ruff format subcommand
  # Correct order: "<ruffCmd> format" is the positional command, then "--nbqa-shell" flag
  testNbqaFormatOptionsStructure = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
    options = formatters.python-notebook-format.options;
    optionsStr = lib.concatStringsSep " " options;
  in {
    expr = lib.hasInfix "--nbqa-shell" optionsStr && lib.hasInfix "format" optionsStr;
    expected = true;
  };

  # Test that the positional ruff command comes before --nbqa-shell flag
  testNbqaFormatArgOrder = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
    options = formatters.python-notebook-format.options;
    # First element is the tool command (ruff format), second is the flag
    firstOption = builtins.head options;
    secondOption = builtins.elemAt options 1;
  in {
    expr = lib.hasInfix "format" firstOption && secondOption == "--nbqa-shell";
    expected = true;
  };

  # Test custom ruff command
  testNbqaCustomRuffCommand = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa = {
            enable = true;
            ruffCommand = "/custom/path/to/ruff";
          };
        };
      }
    ];
    options = formatters.python-notebook-format.options;
    optionsStr = lib.concatStringsSep " " options;
  in {
    expr = lib.hasInfix "/custom/path/to/ruff" optionsStr;
    expected = true;
  };

  # Test trailing "--" sentinel is added (required by treefmt/nbqa)
  testNbqaFormatTrailingSentinel = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
    options = formatters.python-notebook-format.options;
    lastOption = lib.last options;
  in {
    expr = lastOption == "--";
    expected = true;
  };
}
