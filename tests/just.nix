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

  getPerSystemCfg = modules: (evalFlake modules).config.perSystem system;

  mkTestPackage = name:
    builtins.derivation {
      inherit name system;
      builder = "/bin/sh";
      args = ["-c" "mkdir -p \"$out/bin\" && touch \"$out/bin/${name}\" \"$out/bin/mypy\""];
    };

  mkConfigModule = {
    pythonEnvs ? {},
    pythonDefaultEnv ? null,
    extraChecks ? {},
  }: {
    _module.check = false;
    jackpkgs.checks = lib.recursiveUpdate
      {
        python = {
          enable = true;
          mypy.enable = true;
        };
      }
      extraChecks;

    jackpkgs.outputs = {
      pythonEnvironments = pythonEnvs;
      inherit pythonDefaultEnv;
      pulumiJustfile = "";
    };

    perSystem = {pkgs, ...}: {
      _module.args.jackpkgsProjectRoot = null;
      _module.args.pythonWorkspace = {
        computeSpec = {includeGroups ? false}:
          if includeGroups
          then {_groups = true;}
          else {};
        mkEnv = {
          name,
          spec,
        }:
          builtins.derivation {
            inherit system name;
            builder = "/bin/sh";
            args = ["-c" "mkdir -p \"$out/bin\" && touch \"$out/bin/${name}\""];
          };
      };
      jackpkgs.pulumi.secretsProvider = "unused";
    };
  };

  allSubstringsPresent = needles: haystack: lib.all (needle: lib.hasInfix needle haystack) needles;
in {
  testJustMypyPackagePrefersDevToolsEnv = let
    devToolsEnv = mkTestPackage "python-dev-tools";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonEnvs.dev = devToolsEnv;
        pythonDefaultEnv = mkTestPackage "python-default";
        extraChecks.python.ruff.enable = false;
      })
      {
        jackpkgs.python.environments.dev = {
          editable = false;
          includeGroups = true;
        };
      }
    ];
  in {
    expr = perSystemCfg.jackpkgs.just.mypyPackage == devToolsEnv;
    expected = true;
  };

  testJustLintUsesSelectedMypyPackage = let
    devToolsEnv = mkTestPackage "python-dev-tools";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonEnvs.dev = devToolsEnv;
        extraChecks.python.ruff.enable = false;
      })
      {
        jackpkgs.python.environments.dev = {
          editable = false;
          includeGroups = true;
        };
      }
    ];
    lintJustfile = perSystemCfg.just-flake.features.nix.justfile;
  in {
    expr = allSubstringsPresent ["==> mypy" "${devToolsEnv}/bin/mypy ."] lintJustfile;
    expected = true;
  };

  testJustMypyPackageFallsBackToPythonDefaultEnv = let
    defaultEnv = mkTestPackage "python-default";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonDefaultEnv = defaultEnv;
        extraChecks.python.ruff.enable = false;
      })
    ];
  in {
    expr = perSystemCfg.jackpkgs.just.mypyPackage == defaultEnv;
    expected = true;
  };
}
