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

            packages = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = ''
                List of workspace packages to type-check per-commit.

                Defaults to `jackpkgs.checks.typescript.tsc.packages` (which
                itself defaults to auto-discovery from pnpm-workspace.yaml).
                Override here only if you need a different set for the pre-commit
                hook than for CI.
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

            packages = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = ''
                List of workspace packages to run vitest for pre-push.

                Defaults to `jackpkgs.checks.vitest.packages` (which itself
                defaults to auto-discovery from pnpm-workspace.yaml).
                Override here only if you need a different set for the pre-commit
                hook than for CI.
              '';
            };
          };
        };

        biome = {
          lint = {
            package = mkOption {
              type = types.package;
              default = pkgs.nodejs;
              defaultText = "pkgs.nodejs";
              description = "Node.js runtime package used to execute biome.";
            };

            nodeModules = mkOption {
              type = types.nullOr types.package;
              default = null;
              description = ''
                Derivation containing a `node_modules` tree (including the
                `biome` binary) to link before running the hook.

                When null, falls back to `config.jackpkgs.outputs.nodeModules`
                if available.
              '';
            };

            packages = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = ''
                List of workspace packages to lint per-commit.

                Defaults to `jackpkgs.checks.biome.lint.packages` (which itself
                defaults to auto-discovery from pnpm-workspace.yaml).
                Override here only if you need a different set for the pre-commit
                hook than for CI.
              '';
            };
          };
        };

        adr = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to enable the ADR conflict-check pre-commit hook.

              When enabled, the hook validates that all `.md` files in
              `jackpkgs.pre-commit.adr.directory` have:
                - well-formed filenames (`NNN-*.md`)
                - unique three-digit prefixes (no duplicates)
                - a contiguous numeric sequence with no gaps (001…N)

              `000` is reserved for the ADR template and is excluded from
              gap detection.
            '';
          };

          directory = mkOption {
            type = types.str;
            default = "docs/internal/decisions";
            description = ''
              Path (relative to the repo root, or absolute) to the directory
              containing ADR files.  Passed as `--adr-dir` to
              `adr-conflict-check`.
            '';
          };

          package = mkOption {
            type = types.package;
            default = pkgs.adr-conflict-check;
            defaultText = "pkgs.adr-conflict-check";
            description = "The `adr-conflict-check` package to use.";
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
        jackpkgsProjectRoot ? null,
        ...
      }: let
        sysCfg = config.jackpkgs.pre-commit;

        # jackpkgsLib (from top-level _module.args) only contains nodejs-helpers
        # which are lib-only.  Augment it with pkgs-aware helpers from
        # lib/default.nix (mkFromYAML, etc.) that require pkgs, only available
        # inside perSystem.
        jackpkgsLibFull =
          jackpkgsLib // (import ../../lib {inherit pkgs;});

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

        # Mirror checks.nix: resolve projectRoot the same way so workspace
        # package discovery is consistent between CI checks and pre-commit hooks.
        projectRoot =
          if jackpkgsProjectRoot != null
          then jackpkgsProjectRoot
          else config.jackpkgs.projectRoot or inputs.self.outPath;

        # YAML parser for pnpm-workspace.yaml.
        # Uses the shared mkFromYAML from jackpkgsLib with the JSON-sidecar
        # optimisation enabled, matching checks.nix behaviour.  Previously
        # pre-commit.nix always invoked yq-go IFD, which was slower and
        # silently diverged from the CI path.
        preCommitFromYAML = jackpkgsLibFull.mkFromYAML {jsonSidecar = true;};

        discoverPnpmPackages = workspaceRoot:
          jackpkgsLib.discoverPnpmPackages {
            inherit workspaceRoot;
            fromYAML = preCommitFromYAML;
          };

        tscPackages =
          if sysCfg.typescript.tsc.packages != null
          then map jackpkgsLib.validateWorkspacePath sysCfg.typescript.tsc.packages
          else if (lib.attrByPath ["typescript" "tsc" "packages"] null checksCfg) != null
          then map jackpkgsLib.validateWorkspacePath checksCfg.typescript.tsc.packages
          else discoverPnpmPackages projectRoot;

        vitestPackages =
          if sysCfg.javascript.vitest.packages != null
          then map jackpkgsLib.validateWorkspacePath sysCfg.javascript.vitest.packages
          else if (lib.attrByPath ["vitest" "packages"] null checksCfg) != null
          then map jackpkgsLib.validateWorkspacePath checksCfg.vitest.packages
          else discoverPnpmPackages projectRoot;

        biomeNodeModules =
          if sysCfg.biome.lint.nodeModules != null
          then sysCfg.biome.lint.nodeModules
          else defaultNodeModules;

        biomePackages =
          if sysCfg.biome.lint.packages != null
          then map jackpkgsLib.validateWorkspacePath sysCfg.biome.lint.packages
          else if (lib.attrByPath ["biome" "lint" "packages"] null checksCfg) != null
          then map jackpkgsLib.validateWorkspacePath checksCfg.biome.lint.packages
          else discoverPnpmPackages projectRoot;

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

        biomeLintEntry = "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
          ${lib.optionalString (biomeNodeModules != null) (mkNodeModulesSetup biomeNodeModules)}
          ${lib.optionalString (biomeNodeModules != null) (jackpkgsLib.mkWorkspaceSymlinks projectRoot biomePackages)}
          if command -v biome >/dev/null 2>&1; then
            BIOME_BIN="biome"
          else
            cat >&2 <<'EOF'
            ERROR: biome binary not found for lint pre-commit hook.

            Enable the Node.js module so that biome is available via node_modules:

                jackpkgs.nodejs.enable = true;

            Or set a custom node_modules derivation:

                jackpkgs.pre-commit.biome.lint.nodeModules = <derivation>;

            To disable the Biome lint hook:

                jackpkgs.checks.biome.lint.enable = false;
            EOF
            exit 1
          fi

          ${lib.concatMapStringsSep "\n" (pkg: ''
              (cd ${lib.escapeShellArg pkg} && "$BIOME_BIN" lint${escapeExtraArgs checksCfg.biome.lint.extraArgs} .)
            '')
            biomePackages}
        ''}";

        tscExe = lib.getExe' sysCfg.typescript.tsc.package "tsc";

        tscEntry =
          if tscNodeModules != null
          then "${lib.getExe pkgs.bash} -euo pipefail -c ${lib.escapeShellArg ''
            ${mkNodeModulesSetup tscNodeModules}
            ${jackpkgsLib.mkWorkspaceSymlinks projectRoot tscPackages}
            ${lib.concatMapStringsSep "\n" (pkg: ''
                (cd ${lib.escapeShellArg pkg} && ${tscExe} --noEmit${escapeExtraArgs checksCfg.typescript.tsc.extraArgs})
              '')
              tscPackages}
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
          ${lib.optionalString (vitestNodeModules != null) (jackpkgsLib.mkWorkspaceSymlinks projectRoot vitestPackages)}
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

          ${lib.concatMapStringsSep "\n" (pkg: ''
              (cd ${lib.escapeShellArg pkg} && "$VITEST_BIN" run${escapeExtraArgs checksCfg.vitest.extraArgs})
            '')
            vitestPackages}
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

          settings.hooks.biome-lint = {
            enable = lib.attrByPath ["biome" "lint" "enable"] false checksCfg;
            package = sysCfg.biome.lint.package;
            entry = biomeLintEntry;
            files = "\\.(js|ts|jsx|tsx|json|jsonc|json5)$";
            pass_filenames = false;
          };

          settings.hooks.adr-conflict-check = {
            enable = sysCfg.adr.enable;
            package = sysCfg.adr.package;
            entry = "${lib.getExe sysCfg.adr.package} --adr-dir ${sysCfg.adr.directory}";
            files = "\\.md$";
            pass_filenames = false;
          };
        };
      };
    }
  );
}
