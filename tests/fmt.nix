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
    perSystemCfg.treefmt.config or {};

  getSettingsFormatter = modules:
    (getTreefmtConfig modules).settings.formatter or {};

  hasInfixAll = needles: haystack: lib.all (n: lib.hasInfix n haystack) needles;
in {
  # Test that nbqa formatters are not created when disabled (default)
  testNbqaDisabledByDefault = let
    formatters = getSettingsFormatter [{}];
  in {
    expr = !(lib.hasAttr "python-notebook-format" formatters) && !(lib.hasAttr "python-notebook-lint" formatters);
    expected = true;
  };

  # Test that nbqa formatters are created when enabled
  testNbqaEnabledCreatesFormatters = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
  in {
    expr = lib.hasAttr "python-notebook-format" formatters && lib.hasAttr "python-notebook-lint" formatters;
    expected = true;
  };

  # Test that formatters have correct command
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

  # Test ruff check options are passed
  testNbqaRuffCheckOptions = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa = {
            enable = true;
            ruffCheckOptions = ["--line-length=88" "--select=I,E,F"];
          };
        };
      }
    ];
    options = formatters.python-notebook-lint.options;
    optionsStr = lib.concatStringsSep " " options;
  in {
    expr = lib.hasInfix "--line-length=88" optionsStr && lib.hasInfix "--select=I,E,F" optionsStr;
    expected = true;
  };

  # Test format options include shell mode and ruff format command
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

  # Test lint options include shell mode and ruff check --fix command
  testNbqaLintOptionsStructure = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.enable = true;
        };
      }
    ];
    options = formatters.python-notebook-lint.options;
    optionsStr = lib.concatStringsSep " " options;
  in {
    expr = lib.hasInfix "--nbqa-shell" optionsStr && lib.hasInfix "check --fix" optionsStr;
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
}
