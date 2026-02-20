{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  jackpkgsLib,
  ...
}: let
  inherit (lib) mkIf;
  inherit (jackpkgsInputs.self.lib) defaultExcludes;
  pythonEnvHelpers = import ../../lib/python-env-selection.nix {inherit lib;};
  cfg = config.jackpkgs.pre-commit;
in {
  imports = [
    jackpkgsInputs.pre-commit-hooks.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pre-commit = {
      enable = mkEnableOption "jackpkgs-pre-commit" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: let
      pythonCfg = config.jackpkgs.python or {};
      pythonWorkspace = config._module.args.pythonWorkspace or null;
      pythonEnvOutputs = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} config;
      pythonEnvWithDevTools = pythonEnvHelpers.selectPythonEnvWithDevTools {
        inherit pythonCfg pythonWorkspace pythonEnvOutputs;
      };
      pythonDefaultEnv = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;

      mypyDefaultPackage =
        if pythonEnvWithDevTools != null
        then pythonEnvWithDevTools
        else if pythonDefaultEnv != null
        then pythonDefaultEnv
        else config.jackpkgs.pkgs.mypy;
    in {
      options.jackpkgs.pre-commit = {
        treefmtPackage = mkOption {
          type = types.package;
          default = config.treefmt.build.wrapper;
          defaultText = "config.treefmt.build.wrapper";
          description = "treefmt package to use.";
        };

        nbstripoutPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.nbstripout;
          defaultText = "config.jackpkgs.pkgs.nbstripout";
          description = "nbstripout package to use.";
        };

        python = {
          mypy = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable the pre-commit mypy hook.";
            };

            package = mkOption {
              type = types.package;
              default = mypyDefaultPackage;
              defaultText = ''
                Dev-tools Python env (same precedence as `checks.nix`):
                1. `jackpkgs.python.environments.dev` if non-editable and `includeGroups = true`
                2. Any non-editable `jackpkgs.python.environments.*` with `includeGroups = true`
                3. Auto-created env with `includeGroups = true` (via `pythonWorkspace`)
                4. `jackpkgs.python.environments.default` (when defined)
                5. `config.jackpkgs.pkgs.mypy`
              '';
              description = ''
                mypy package (or Python environment containing mypy) to use for
                the pre-commit mypy hook.

                Defaults to the same dev-tools environment selection used by
                `checks.nix` CI checks, preferring a non-editable environment
                with dependency groups enabled.
              '';
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Extra arguments passed to mypy.";
              example = ["--strict"];
            };
          };

          ruff = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable the pre-commit ruff hook.";
            };

            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.mypy.package;
              defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
              description = "ruff package (or Python environment containing ruff) to use.";
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = ["--no-cache"];
              description = "Extra arguments passed to ruff check.";
              example = ["--no-cache"];
            };
          };

          pytest = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable the pre-commit pytest hook.";
            };

            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.mypy.package;
              defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
              description = "pytest package (or Python environment containing pytest) to use.";
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Extra arguments passed to pytest.";
              example = ["-q"];
            };
          };

          numpydoc = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable the pre-commit numpydoc docstring validation hook.

                Requires `numpydoc` to be available in `package`.
              '';
            };

            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.mypy.package;
              defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
              description = ''
                Python package (or environment) that provides
                `python -m numpydoc.hooks.validate_docstrings`.
              '';
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Extra arguments passed to numpydoc.hooks.validate_docstrings.";
              example = ["--checks" "all"];
            };
          };
        };

        typescript = {
          tsc = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable the pre-commit tsc hook.";
            };

            package = mkOption {
              type = types.package;
              default = pkgs.nodePackages.typescript;
              defaultText = "pkgs.nodePackages.typescript";
              description = "TypeScript package providing the `tsc` executable.";
            };

            nodeModules = mkOption {
              type = types.nullOr types.package;
              default = null;
              description = ''
                Derivation containing a `node_modules` tree to link before
                running the hook.

                When null, falls back to `config.jackpkgs.outputs.nodeModules`
                if available.
              '';
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Extra arguments passed to tsc --noEmit.";
              example = ["--pretty" "false"];
            };
          };
        };

        javascript = {
          vitest = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable the pre-commit vitest hook.";
            };

            package = mkOption {
              type = types.package;
              default = pkgs.nodejs;
              defaultText = "pkgs.nodejs";
              description = "Node.js runtime package used to execute vitest.";
            };

            nodeModules = mkOption {
              type = types.nullOr types.package;
              default = null;
              description = ''
                Derivation containing a `node_modules` tree to link before
                running the hook.

                When null, falls back to `config.jackpkgs.outputs.nodeModules`
                if available.
              '';
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Extra arguments passed to `vitest run`.";
              example = ["--coverage"];
            };
          };
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      sysCfg = config.jackpkgs.pre-commit;

      escapeExtraArgs = args:
        lib.optionalString (args != []) " ${lib.escapeShellArgs args}";

      defaultNodeModules = lib.attrByPath ["jackpkgs" "outputs" "nodeModules"] null config;
      tscNodeModules =
        if sysCfg.typescript.tsc.nodeModules != null
        then sysCfg.typescript.tsc.nodeModules
        else defaultNodeModules;
      vitestNodeModules =
        if sysCfg.javascript.vitest.nodeModules != null
        then sysCfg.javascript.vitest.nodeModules
        else defaultNodeModules;

      mkNodeModulesSetup = nodeModules: ''
        nm_store=${lib.escapeShellArg (toString nodeModules)}
        ${jackpkgsLib.nodejs.findNodeModulesRoot "nm_root" "$nm_store"}
        if [ -z "$nm_root" ]; then
          echo "ERROR: Unable to find node_modules in $nm_store" >&2
          exit 1
        fi
        ln -sfn "$nm_root" node_modules
        ${jackpkgsLib.nodejs.findNodeModulesBin "nm_bin" "$nm_store"}
        if [ -n "$nm_bin" ]; then
          export PATH="$nm_bin:$PATH"
        fi
      '';

      tscExe = lib.getExe' sysCfg.typescript.tsc.package "tsc";

      tscEntry =
        if tscNodeModules != null
        then
          "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
            ${mkNodeModulesSetup tscNodeModules}
            ${tscExe} --noEmit${escapeExtraArgs sysCfg.typescript.tsc.extraArgs}
          ''}"
        else "${tscExe} --noEmit${escapeExtraArgs sysCfg.typescript.tsc.extraArgs}";

      vitestEntry = "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
        ${lib.optionalString (vitestNodeModules != null) (mkNodeModulesSetup vitestNodeModules)}
        if [ -x "./node_modules/.bin/vitest" ]; then
          VITEST_BIN="./node_modules/.bin/vitest"
        elif command -v vitest >/dev/null 2>&1; then
          VITEST_BIN="vitest"
        else
          echo "ERROR: vitest binary not found. Configure jackpkgs.pre-commit.javascript.vitest.nodeModules or ensure vitest is available in PATH." >&2
          exit 1
        fi

        "$VITEST_BIN" run${escapeExtraArgs sysCfg.javascript.vitest.extraArgs}
      ''}";
    in {
      pre-commit = {
        check.enable = true;

        settings.hooks.treefmt = {
          enable = true;
          package = sysCfg.treefmtPackage;
        };

        settings.hooks.nbstripout = {
          enable = true;
          package = sysCfg.nbstripoutPackage;
          entry = "${lib.getExe sysCfg.nbstripoutPackage}";
          files = "\\.ipynb$";
        };

        settings.hooks.mypy = {
          enable = sysCfg.python.mypy.enable;
          package = sysCfg.python.mypy.package;
          entry = "${lib.getExe' sysCfg.python.mypy.package "mypy"}${escapeExtraArgs sysCfg.python.mypy.extraArgs}";
          files = "\\.py$";
          excludes = defaultExcludes.preCommit;
        };

        settings.hooks.ruff = {
          enable = sysCfg.python.ruff.enable;
          package = sysCfg.python.ruff.package;
          entry = "${lib.getExe' sysCfg.python.ruff.package "ruff"} check${escapeExtraArgs sysCfg.python.ruff.extraArgs}";
          files = "\\.py$";
          excludes = defaultExcludes.preCommit;
        };

        settings.hooks.pytest = {
          enable = sysCfg.python.pytest.enable;
          package = sysCfg.python.pytest.package;
          entry = "${lib.getExe' sysCfg.python.pytest.package "pytest"}${escapeExtraArgs sysCfg.python.pytest.extraArgs}";
          files = "\\.py$";
          stages = ["pre-push"];
          pass_filenames = false;
        };

        settings.hooks.numpydoc = {
          enable = sysCfg.python.numpydoc.enable;
          package = sysCfg.python.numpydoc.package;
          entry = let
            pythonExe = lib.getExe' sysCfg.python.numpydoc.package "python";
          in "${pythonExe} -m numpydoc.hooks.validate_docstrings${escapeExtraArgs sysCfg.python.numpydoc.extraArgs}";
          files = "\\.py$";
          excludes = defaultExcludes.preCommit;
        };

        settings.hooks.tsc = {
          enable = sysCfg.typescript.tsc.enable;
          package = sysCfg.typescript.tsc.package;
          entry = tscEntry;
          files = "\\.(ts|tsx)$";
          pass_filenames = false;
        };

        settings.hooks.vitest = {
          enable = sysCfg.javascript.vitest.enable;
          package = sysCfg.javascript.vitest.package;
          entry = vitestEntry;
          files = "\\.(js|ts|jsx|tsx)$";
          stages = ["pre-push"];
          pass_filenames = false;
        };
      };
    };
  };
}
