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
in {
  testNotebookFormattersDisabledByDefault = let
    formatters = getSettingsFormatter [{}];
  in {
    expr = !(lib.hasAttr "python-notebook-format" formatters) && !(lib.hasAttr "python-myst-notebook-format" formatters);
    expected = true;
  };

  testIpynbFormatterEnabledCreatesFormatter = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.ipynb.enable = true;
        };
      }
    ];
  in {
    expr = lib.hasAttr "python-notebook-format" formatters;
    expected = true;
  };

  testMystFormatterEnabledCreatesFormatter = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.myst = {
            enable = true;
            includes = ["docs/**/*.md"];
          };
        };
      }
    ];
  in {
    expr = lib.hasAttr "python-myst-notebook-format" formatters;
    expected = true;
  };

  testIpynbFormatterCommand = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.ipynb.enable = true;
        };
      }
    ];
  in {
    expr = lib.hasInfix "nbqa" formatters.python-notebook-format.command;
    expected = true;
  };

  testMystFormatterCommand = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.myst = {
            enable = true;
            includes = ["docs/**/*.md"];
          };
        };
      }
    ];
  in {
    expr = lib.hasInfix "jupytext" formatters.python-myst-notebook-format.command;
    expected = true;
  };

  testIpynbDefaultIncludes = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.ipynb.enable = true;
        };
      }
    ];
  in {
    expr = formatters.python-notebook-format.includes;
    expected = ["*.ipynb"];
  };

  testMystCustomIncludes = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.myst = {
            enable = true;
            includes = ["docs/**/*.md"];
          };
        };
      }
    ];
  in {
    expr = formatters.python-myst-notebook-format.includes;
    expected = ["docs/**/*.md"];
  };

  testIpynbRuffFormatOptions = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa = {
            ipynb.enable = true;
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

  testIpynbFormatArgOrder = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.ipynb.enable = true;
        };
      }
    ];
    options = formatters.python-notebook-format.options;
    firstOption = builtins.head options;
    secondOption = builtins.elemAt options 1;
    lastOption = lib.last options;
  in {
    expr = lib.hasInfix "format" firstOption && secondOption == "--nbqa-shell" && lastOption == "--";
    expected = true;
  };

  testMystFormatOptionsStructure = let
    formatters = getSettingsFormatter [
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.fmt.nbqa.myst = {
            enable = true;
            includes = ["docs/**/*.md"];
          };
        };
      }
    ];
    options = formatters.python-myst-notebook-format.options;
    optionsStr = lib.concatStringsSep " " options;
  in {
    expr = lib.hasInfix "--pipe" optionsStr && lib.hasInfix "ruff format {}" optionsStr && lib.hasInfix "--pipe-fmt" optionsStr && lib.hasInfix "py:percent" optionsStr;
    expected = true;
  };
}
