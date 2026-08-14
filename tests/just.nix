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

  pnpmWorkspace = ./fixtures/checks/pnpm-workspace;

  # Same test double as tests/checks.nix: avoids real yq-go IFD while
  # exercising the actual auto-discovery decision (packages = null).
  mockFromYAML = yamlFile:
    if builtins.baseNameOf yamlFile == "pnpm-workspace.yaml"
    then {packages = ["packages/*" "tools/*"];}
    else {};

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
      args = ["-c" "mkdir -p \"$out/bin\" && touch \"$out/bin/${name}\" \"$out/bin/ty\" \"$out/bin/ruff\""];
    };

  mkConfigModule = {
    pythonEnvs ? {},
    pythonDefaultEnv ? null,
    extraChecks ? {},
    withPythonWorkspace ? true,
    # ADR 045: checks.python.environment is per-system, so set it in perSystem.
    checkEnvironment ? null,
    projectRoot ? null,
  }: {
    _module.check = false;
    jackpkgs.pulumi.secretsProvider = "unused";
    jackpkgs.checks =
      lib.recursiveUpdate
      {
        python = {
          enable = true;
          ty.enable = true;
        };
      }
      extraChecks;

    jackpkgs.outputs = {
      pythonEnvironments = pythonEnvs;
      inherit pythonDefaultEnv;
      pulumiJustfile = "";
    };

    perSystem = {pkgs, ...}:
      {
        # NOTE: `_module.args` is combined here as ONE attrset before being
        # assigned. `{_module.args.a = ...;} // {_module.args.b = ...;}` is a
        # trap: `//` only merges the outer `_module` key, so the second
        # attrset's `args` value replaces (not extends) the first — `a` is
        # silently dropped, not merged with `b`.
        _module.args =
          {jackpkgsProjectRoot = projectRoot;}
          // lib.optionalAttrs withPythonWorkspace {
            pythonWorkspace = {
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
          };
      }
      // lib.optionalAttrs (checkEnvironment != null) {
        jackpkgs.checks.python.environment = checkEnvironment;
      };
  };
in {
  testJustTyEnvironmentPackagePrefersDevToolsEnv = let
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
    expr = perSystemCfg.jackpkgs.just.tyEnvironmentPackage == devToolsEnv;
    expected = true;
  };

  testJustTyEnvironmentPackageFallsBackToPythonDefaultEnv = let
    defaultEnv = mkTestPackage "python-default";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonDefaultEnv = defaultEnv;
        extraChecks.python.ruff.enable = false;
        withPythonWorkspace = false;
      })
    ];
  in {
    expr = perSystemCfg.jackpkgs.just.tyEnvironmentPackage == defaultEnv;
    expected = true;
  };

  # ADR 045 §6: the global `checks.python.environment` wins first for the
  # `just lint` tool-env selection too.
  testJustTyEnvironmentPackageHonorsGlobalEnvironment = let
    globalEnv = mkTestPackage "python-global";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonEnvs.dev = mkTestPackage "python-dev-tools";
        pythonDefaultEnv = mkTestPackage "python-default";
        checkEnvironment = globalEnv;
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
    expr = perSystemCfg.jackpkgs.just.tyEnvironmentPackage == globalEnv;
    expected = true;
  };

  testJustRuffPackagePrefersDevToolsEnv = let
    devToolsEnv = mkTestPackage "python-dev-tools";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonEnvs.dev = devToolsEnv;
        pythonDefaultEnv = mkTestPackage "python-default";
        extraChecks.python.ty.enable = false;
      })
      {
        jackpkgs.python.environments.dev = {
          editable = false;
          includeGroups = true;
        };
      }
    ];
  in {
    expr = perSystemCfg.jackpkgs.just.ruffPackage == devToolsEnv;
    expected = true;
  };

  testJustRuffPackageFallsBackToPythonDefaultEnv = let
    defaultEnv = mkTestPackage "python-default";
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        pythonDefaultEnv = defaultEnv;
        extraChecks.python.ty.enable = false;
        withPythonWorkspace = false;
      })
    ];
  in {
    expr = perSystemCfg.jackpkgs.just.ruffPackage == defaultEnv;
    expected = true;
  };

  # Regression test for the just.nix package-resolution gap: with
  # `typescript.tsc.packages` at its default (null, meaning "auto-discover
  # from pnpm-workspace.yaml"), `just lint` used to read the raw null and
  # silently skip tsc entirely instead of resolving the workspace like
  # checks.nix/pre-commit.nix do.
  testJustLintRunsTscWhenPackagesAutoDiscovered = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        extraChecks = {
          typescript.tsc.enable = true;
          # Keep the recipe body to just tsc: these tools' python-env
          # resolution is unrelated to this regression and pulls in
          # derivations this test isn't set up to build.
          python.ty.enable = false;
          python.ruff.enable = false;
          python.pytest.enable = false;
        };
        projectRoot = pnpmWorkspace;
      })
      {jackpkgs.checks.fromYAML = mockFromYAML;}
    ];
    # `just-flake.features.nix.justfile` is a writeText derivation, not a
    # plain string — `.text` reads the content pkgs.writeText was given
    # directly (a plain derivation attribute, available without a build),
    # avoiding a full realize of every package referenced anywhere in the
    # combined "nix" recipe group (flake-iter, jq, ...) just to assert on
    # the tsc section.
    lintJustfile = perSystemCfg.just-flake.features.nix.justfile.text;
  in {
    expr =
      lib.hasInfix "# tsc (TypeScript type checker)" lintJustfile
      && lib.hasInfix "packages/app" lintJustfile
      && lib.hasInfix "tools/cli" lintJustfile;
    expected = true;
  };

  # Same gap, vitest side: `just test` used to read the raw
  # `vitest.packages` null and silently skip, so a workspace with no
  # explicit `packages` list got zero test coverage from `just test` while
  # `nix flake check` ran vitest against the discovered packages.
  testJustTestRunsVitestWhenPackagesAutoDiscovered = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        extraChecks = {
          vitest.enable = true;
          python.ty.enable = false;
          python.ruff.enable = false;
          python.pytest.enable = false;
        };
        projectRoot = pnpmWorkspace;
      })
      {jackpkgs.checks.fromYAML = mockFromYAML;}
    ];
    testJustfile = perSystemCfg.just-flake.features.nix.justfile.text;
  in {
    expr =
      lib.hasInfix "# vitest (JS/TS tests)" testJustfile
      && lib.hasInfix "packages/app" testJustfile
      && lib.hasInfix "tools/cli" testJustfile;
    expected = true;
  };
}
