{jackpkgsInputs}: {
  inputs,
  config,
  options,
  lib,
  jackpkgsLib,
  ...
} @ moduleTop: let
  inherit (lib) mkIf;
  inherit (jackpkgsInputs.self.lib) defaultExcludes;
  pythonEnvHelpers = import ../../lib/python-env-selection.nix {inherit lib;};
  cfg = config.jackpkgs.pre-commit;
  jackpkgsPythonCfg = config.jackpkgs.python or {};
  checksOptionsDefined = lib.hasAttrByPath ["jackpkgs" "checks"] options;
  checksCfg = lib.attrByPath ["jackpkgs" "checks"] {} config;
  mypyDeprecationWarning = ''echo 'WARNING: mypy is deprecated. Migrate to ty: jackpkgs.checks.python.mypy.typeChecker = "ty"' >&2'';
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
    }: {
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
              default = config.jackpkgs.pkgs.mypy;
              defaultText = ''
                Dev-tools Python env (same precedence as `checks.nix`):
                1. `jackpkgs.python.environments.dev` if non-editable and `includeGroups = true`
                2. Any non-editable `jackpkgs.python.environments.*` with `includeGroups = true`
                3. Auto-created env with `includeGroups = true` (via `pythonWorkspace`)
                4. `config.jackpkgs.outputs.pythonDefaultEnv` (when defined)
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

            tyPackage = mkOption {
              type = types.package;
              default = config.jackpkgs.pkgs.ty;
              defaultText = "config.jackpkgs.pkgs.ty";
              description = ''
                `ty` binary package to use when `jackpkgs.checks.python.mypy.typeChecker = "ty"`.
                Defaults to `config.jackpkgs.pkgs.ty` (nixpkgs).
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
              default = config.jackpkgs.pkgs.typescript;
              defaultText = "config.jackpkgs.pkgs.typescript";
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
              default =
                lib.attrByPath ["jackpkgs" "nodejs" "package"]
                (lib.attrByPath ["jackpkgs" "pkgs" "nodejs_24"] pkgs.nodejs_24 config)
                config;
              defaultText = ''                lib.attrByPath ["jackpkgs" "nodejs" "package"]
                                (lib.attrByPath ["jackpkgs" "pkgs" "nodejs_24"] pkgs.nodejs_24 config)
                                config'';
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
              default =
                lib.attrByPath ["jackpkgs" "nodejs" "package"]
                (lib.attrByPath ["jackpkgs" "pkgs" "nodejs_24"] pkgs.nodejs_24 config)
                config;
              defaultText = ''                lib.attrByPath ["jackpkgs" "nodejs" "package"]
                                (lib.attrByPath ["jackpkgs" "pkgs" "nodejs_24"] pkgs.nodejs_24 config)
                                config'';
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

        # Create a writable node_modules directory populated with symlinks into
        # the store.  Mirrors the linkNodeModules strategy in checks.nix: a
        # single symlink to the read-only store would prevent mkWorkspaceSymlinks
        # from creating workspace package symlinks (mkdir -p node_modules/@scope
        # fails inside a read-only symlink target).
        mkNodeModulesSetup = nodeModules: let
          nmStore = lib.escapeShellArg (toString nodeModules);
        in ''
          nm_store=${nmStore}
          ${jackpkgsLib.nodejs.findNodeModulesRoot "nm_root" "$nm_store"}
          if [ -z "$nm_root" ]; then
            echo "ERROR: Unable to find node_modules in $nm_store" >&2
            exit 1
          fi
          mkdir -p node_modules
          shopt -s dotglob
          for entry in "$nm_root"/*/; do
            entry_name="$(basename "$entry")"
            if [[ "$entry_name" == @* ]]; then
              mkdir -p "node_modules/$entry_name"
              for scoped_pkg in "$entry"*/; do
                ln -sfn "$scoped_pkg" "node_modules/$entry_name/$(basename "$scoped_pkg")"
              done
            else
              ln -sfn "$entry" "node_modules/$entry_name"
            fi
          done
          shopt -u dotglob
          ${jackpkgsLib.nodejs.findNodeModulesBin "nm_bin" "$nm_store"}
          if [ -n "$nm_bin" ]; then
            export PATH="$nm_bin:$PATH"
          fi
        '';

        # Link per-package node_modules from the derivation store.  pnpm
        # installs package-local dependencies under <store>/<pkg>/node_modules
        # (e.g. @pulumi/cloudflare lives under deploy/platform/cloudflared/
        # node_modules, not at the root).  Without these, tsc --noEmit run
        # inside each package directory cannot resolve its own dependencies.
        linkPackageNodeModules = nodeModules: packages: let
          nmStore = lib.escapeShellArg (toString nodeModules);
        in
          lib.concatMapStringsSep "\n" (pkg: ''
            mkdir -p ${lib.escapeShellArg pkg}
            if [ -d ${nmStore}/${lib.escapeShellArg pkg}/node_modules ]; then
              ln -sfn ${nmStore}/${lib.escapeShellArg pkg}/node_modules ${lib.escapeShellArg pkg}/node_modules
            elif [ -d "$nm_root"/${lib.escapeShellArg pkg}/node_modules ]; then
              ln -sfn "$nm_root"/${lib.escapeShellArg pkg}/node_modules ${lib.escapeShellArg pkg}/node_modules
            fi
          '')
          packages;

        biomeLintEntry = lib.getExe (pkgs.writeShellApplication {
          name = "biome-lint-hook";
          runtimeInputs = lib.optionals (biomeNodeModules != null) [biomeNodeModules];
          text = ''
            ${lib.optionalString (biomeNodeModules != null) (mkNodeModulesSetup biomeNodeModules)}
            ${lib.optionalString (biomeNodeModules != null) (jackpkgsLib.mkWorkspaceSymlinks projectRoot biomePackages)}
            ${lib.optionalString (biomeNodeModules != null) (linkPackageNodeModules biomeNodeModules biomePackages)}
            if command -v biome >/dev/null 2>&1; then
              BIOME_BIN="biome"
            else
              echo 'ERROR: biome binary not found for lint pre-commit hook.' >&2
              echo 'Enable the Node.js module so that biome is available via node_modules:' >&2
              echo '    jackpkgs.nodejs.enable = true;' >&2
              echo 'Or set a custom node_modules derivation:' >&2
              echo '    jackpkgs.pre-commit.biome.lint.nodeModules = <derivation>;' >&2
              echo 'To disable the Biome lint hook:' >&2
              echo '    jackpkgs.checks.biome.lint.enable = false;' >&2
              exit 1
            fi

            ${lib.concatMapStringsSep "\n" (pkg: ''
                (cd ${lib.escapeShellArg pkg} && "$BIOME_BIN" lint${escapeExtraArgs checksCfg.biome.lint.extraArgs} .)
              '')
              biomePackages}
          '';
        });

        tscExe = lib.getExe' sysCfg.typescript.tsc.package "tsc";

        tscEntry =
          if tscNodeModules != null
          then lib.getExe (pkgs.writeShellApplication {
            name = "tsc-hook";
            runtimeInputs = [tscNodeModules];
            text = ''
              ${mkNodeModulesSetup tscNodeModules}
              ${jackpkgsLib.mkWorkspaceSymlinks projectRoot tscPackages}
              ${linkPackageNodeModules tscNodeModules tscPackages}
              ${lib.concatMapStringsSep "\n" (pkg: ''
                  (cd ${lib.escapeShellArg pkg} && "${tscExe}" --noEmit${escapeExtraArgs checksCfg.typescript.tsc.extraArgs})
                '')
                tscPackages}
            '';
          })
          else lib.getExe (pkgs.writeShellApplication {
            name = "tsc-hook-no-modules";
            text = ''
              echo 'ERROR: node_modules not found for TypeScript pre-commit hook.' >&2
              echo 'TypeScript pre-commit hooks require node_modules to be present.' >&2
              echo 'Enable the Node.js module to provide node_modules:' >&2
              echo '    jackpkgs.nodejs.enable = true;' >&2
              echo 'Or set a custom node_modules derivation:' >&2
              echo '    jackpkgs.pre-commit.typescript.tsc.nodeModules = <derivation>;' >&2
              echo 'To disable TypeScript pre-commit hook:' >&2
              echo '    jackpkgs.checks.typescript.tsc.enable = false;' >&2
              exit 1
            '';
          });

        vitestEntry = lib.getExe (pkgs.writeShellApplication {
          name = "vitest-hook";
          runtimeInputs = lib.optionals (vitestNodeModules != null) [vitestNodeModules];
          text = ''
            ${lib.optionalString (vitestNodeModules != null) (mkNodeModulesSetup vitestNodeModules)}
            ${lib.optionalString (vitestNodeModules != null) (jackpkgsLib.mkWorkspaceSymlinks projectRoot vitestPackages)}
            ${lib.optionalString (vitestNodeModules != null) (linkPackageNodeModules vitestNodeModules vitestPackages)}
            if [ -x "./node_modules/.bin/vitest" ]; then
              VITEST_BIN="$(pwd)/node_modules/.bin/vitest"
            elif command -v vitest >/dev/null 2>&1; then
              VITEST_BIN="vitest"
            else
              echo 'ERROR: vitest binary not found for pre-commit hook.' >&2
              echo 'Enable the Node.js module to provide node_modules:' >&2
              echo '    jackpkgs.nodejs.enable = true;' >&2
              echo 'Or set a custom node_modules derivation:' >&2
              echo '    jackpkgs.pre-commit.javascript.vitest.nodeModules = <derivation>;' >&2
              echo 'To disable vitest pre-commit hook:' >&2
              echo '    jackpkgs.checks.vitest.enable = false;' >&2
              exit 1
            fi

            ${lib.concatMapStringsSep "\n" (pkg: ''
                (cd ${lib.escapeShellArg pkg} && "$VITEST_BIN" run --passWithNoTests${escapeExtraArgs checksCfg.vitest.extraArgs})
              '')
              vitestPackages}
          '';
        });
        preCommitMypyPackageDefault = pythonEnvHelpers.selectDevToolsPackage {
          pythonCfg = jackpkgsPythonCfg;
          pythonWorkspace = config._module.args.pythonWorkspace or null;
          pythonEnvOutputs = let
            fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} moduleTop.config;
            fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} config;
          in
            fromFlake // fromSystem;
          pythonDefaultEnv = let
            fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;
            fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null moduleTop.config;
          in
            if fromSystem != null
            then fromSystem
            else fromFlake;
          fallbackPackage = config.jackpkgs.pkgs.mypy;
        };
      in {
        jackpkgs.pre-commit.python.mypy.package = lib.mkDefault preCommitMypyPackageDefault;
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
            package =
              if checksCfg.python.mypy.typeChecker == "ty"
              then sysCfg.python.mypy.tyPackage
              else sysCfg.python.mypy.package;
            # Run the type checker on the whole workspace (same scope as
            # `just lint` / CI checks) instead of per-staged-file.  When
            # pass_filenames is true (the default) pre-commit passes only
            # the staged file paths, and per-file analysis can't resolve the
            # full type graph.
            pass_filenames = false;
            entry =
              if checksCfg.python.mypy.typeChecker == "ty"
              then let
                mypyPkg = sysCfg.python.mypy.package;
                tyBin = lib.getExe sysCfg.python.mypy.tyPackage;
              in lib.getExe (pkgs.writeShellApplication {
                name = "ty-hook";
                runtimeInputs = [sysCfg.python.mypy.tyPackage];
                text = ''
                  "${tyBin}" check --python "${mypyPkg}"${escapeExtraArgs checksCfg.python.mypy.extraArgs} .
                '';
              })
              else let
                mypyPkg = sysCfg.python.mypy.package;
                pythonVersion =
                  if jackpkgsPythonCfg ? pythonPackage && jackpkgsPythonCfg.pythonPackage != null
                  then jackpkgsPythonCfg.pythonPackage.pythonVersion
                      or (lib.versions.majorMinor jackpkgsPythonCfg.pythonPackage.version or "3.12")
                  else "3.12";
              in lib.getExe (pkgs.writeShellApplication {
                name = "mypy-hook";
                runtimeInputs = [mypyPkg];
                text = ''
                  ${mypyDeprecationWarning}
                  export PYTHONPATH="${mypyPkg}/lib/python${pythonVersion}/site-packages"
                  export MYPY_CACHE_DIR="''${TMPDIR:-/tmp}/.mypy_cache"
                  "${lib.getExe' mypyPkg "mypy"}"${escapeExtraArgs checksCfg.python.mypy.extraArgs} .
                '';
              });
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
        };
      };
    }
  );
}
