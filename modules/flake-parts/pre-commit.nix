{jackpkgsInputs}: {
  inputs,
  config,
  options,
  lib,
  jackpkgsLib,
  ...
}: let
  inherit (lib) mkIf;
  inherit (jackpkgsInputs.self.lib) defaultExcludes;
  pythonEnvHelpers = import ../../lib/python-env-selection.nix {inherit lib;};
  cfg = config.jackpkgs.pre-commit;
  checksOptionsDefined = lib.hasAttrByPath ["jackpkgs" "checks"] options;
  checksCfg = lib.attrByPath ["jackpkgs" "checks"] {} config;
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
      pythonWorkspace = config._module.args.pythonWorkspace or null;
      pythonEnvOutputs = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} config;
      pythonEnvWithDevTools = pythonEnvHelpers.selectPythonEnvWithDevTools {
        pythonCfg = config.jackpkgs.python or {};
        inherit pythonWorkspace pythonEnvOutputs;
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
          };

          ruff = {
            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.mypy.package;
              defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
              description = "ruff package (or Python environment containing ruff) to use.";
            };
          };

          pytest = {
            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.mypy.package;
              defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
              description = "pytest package (or Python environment containing pytest) to use.";
            };
          };

          numpydoc = {
            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.mypy.package;
              defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
              description = ''
                Python package (or environment) that provides
                `python -m numpydoc.hooks.validate_docstrings`.
              '';
            };
          };

          notebook = {
            ruff = {
              package = mkOption {
                type = types.package;
                default = config.jackpkgs.pre-commit.python.mypy.package;
                defaultText = "config.jackpkgs.pre-commit.python.mypy.package";
                description = ''
                  Python package (or environment) that provides the `ruff`
                  executable for notebook linting via nbqa.
                '';
              };
            };
          };
        };

        nbqa = {
          package = mkOption {
            type = types.package;
            default = pkgs.nbqa;
            defaultText = "pkgs.nbqa";
            description = "nbqa package to use for notebook pre-commit hooks.";
          };
        };

        typescript = {
          tsc = {
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
          };
        };

        javascript = {
          vitest = {
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
          };
        };
      };
    });
  };

  config = mkIf cfg.enable (
    if !checksOptionsDefined
    then
      throw ''
        jackpkgs.pre-commit requires jackpkgs.checks options.

        Import inputs.jackpkgs.flakeModules.checks (or inputs.jackpkgs.flakeModules.default)
        in your flake modules list before using jackpkgs.pre-commit.
      ''
    else {
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
          then "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
            ${mkNodeModulesSetup tscNodeModules}
            ${tscExe} --noEmit${escapeExtraArgs checksCfg.typescript.tsc.extraArgs}
          ''}"
          else "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
            cat >&2 <<'EOF'
            ERROR: node_modules not found for TypeScript pre-commit hook.

            TypeScript pre-commit hooks require node_modules to be present.

            Enable the Node.js module to provide node_modules:

                jackpkgs.nodejs.enable = true;

            Or set a custom node_modules derivation:

                jackpkgs.pre-commit.typescript.tsc.nodeModules = <derivation>;

            To disable TypeScript pre-commit hook:

                jackpkgs.checks.typescript.tsc.enable = false;
            EOF
            exit 1
          ''}";

        vitestEntry = "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
          ${lib.optionalString (vitestNodeModules != null) (mkNodeModulesSetup vitestNodeModules)}
          if [ -x "./node_modules/.bin/vitest" ]; then
            VITEST_BIN="./node_modules/.bin/vitest"
          elif command -v vitest >/dev/null 2>&1; then
            VITEST_BIN="vitest"
          else
            cat >&2 <<'EOF'
            ERROR: vitest binary not found for pre-commit hook.

            Enable the Node.js module to provide node_modules:

                jackpkgs.nodejs.enable = true;

            Or set a custom node_modules derivation:

                jackpkgs.pre-commit.javascript.vitest.nodeModules = <derivation>;

            To disable vitest pre-commit hook:

                jackpkgs.checks.vitest.enable = false;
            EOF
            exit 1
          fi

          "$VITEST_BIN" run${escapeExtraArgs checksCfg.vitest.extraArgs}
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
            enable = checksCfg.python.mypy.enable;
            package = sysCfg.python.mypy.package;
            entry = "${lib.getExe' sysCfg.python.mypy.package "mypy"}${escapeExtraArgs checksCfg.python.mypy.extraArgs}";
            files = "\\.py$";
            excludes = defaultExcludes.preCommit;
          };

          settings.hooks.ruff = {
            enable = checksCfg.python.ruff.enable;
            package = sysCfg.python.ruff.package;
            entry = "${lib.getExe' sysCfg.python.ruff.package "ruff"} check${escapeExtraArgs checksCfg.python.ruff.extraArgs}";
            files = "\\.py$";
            excludes = defaultExcludes.preCommit;
          };

          settings.hooks.pytest = {
            enable = checksCfg.python.pytest.enable;
            package = sysCfg.python.pytest.package;
            entry = "${lib.getExe' sysCfg.python.pytest.package "pytest"}${escapeExtraArgs checksCfg.python.pytest.extraArgs}";
            files = "\\.py$";
            stages = ["pre-push"];
            pass_filenames = false;
          };

          settings.hooks.numpydoc = {
            enable = checksCfg.python.numpydoc.enable;
            package = sysCfg.python.numpydoc.package;
            entry = let
              pythonExe = lib.getExe' sysCfg.python.numpydoc.package "python";
            in "${pythonExe} -m numpydoc.hooks.validate_docstrings${escapeExtraArgs checksCfg.python.numpydoc.extraArgs} .";
            files = "\\.py$";
            excludes = defaultExcludes.preCommit;
          };

          settings.hooks.nbqa-ruff = {
            enable = checksCfg.python.notebook.ruff.enable;
            package = sysCfg.nbqa.package;
            entry = let
              ruffExe = lib.getExe' sysCfg.python.notebook.ruff.package "ruff";
              nbqaExe = lib.getExe' sysCfg.nbqa.package "nbqa";
            in "${nbqaExe} \"${ruffExe} check\" --nbqa-shell${escapeExtraArgs checksCfg.python.notebook.ruff.extraArgs}";
            files = "\\.(ipynb|qmd)$";
            # nbqa operates on whole files; don't pass filenames (it scans the repo)
            pass_filenames = false;
          };

          settings.hooks.tsc = {
            enable = checksCfg.typescript.tsc.enable;
            package = sysCfg.typescript.tsc.package;
            entry = tscEntry;
            files = "\\.(ts|tsx)$";
            pass_filenames = false;
          };

          settings.hooks.vitest = {
            enable = checksCfg.vitest.enable;
            package = sysCfg.javascript.vitest.package;
            entry = vitestEntry;
            files = "\\.(js|ts|jsx|tsx)$";
            stages = ["pre-push"];
            pass_filenames = false;
          };
        };
      };
    }
  );
}
