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

        nbqa.package = mkOption {
          type = types.package;
          default = pkgs.nbqa;
          defaultText = "pkgs.nbqa";
          description = "nbqa package to use for notebook pre-commit hooks.";
        };

        python = {
          ty = {
            environment = mkOption {
              type = types.package;
              default = config.jackpkgs.pkgs.python3;
              defaultText = ''
                Dev-tools Python env (same precedence as `checks.nix`):
                1. `jackpkgs.checks.python.environment` (the global override), when set
                2. `jackpkgs.python.environments.dev` if non-editable and `includeGroups = true`
                3. Any non-editable `jackpkgs.python.environments.*` with `includeGroups = true`
                4. Auto-created env with `includeGroups = true` (via `pythonWorkspace`)
                5. `config.jackpkgs.outputs.pythonDefaultEnv` (when defined)
                6. `config.jackpkgs.pkgs.python3` (a bare interpreter — a valid
                   `ty --python` target for repos with no configured Python env)
              '';
              description = ''
                Shared dev-tools Python environment for the pre-commit Python
                hooks. It is ty's `--python` resolution target and the default
                environment inherited by the ruff/pytest/numpydoc hooks.

                Defaults to the same dev-tools environment selection used by
                `checks.nix` CI checks (preferring
                `jackpkgs.checks.python.environment` when set), so one
                declaration keeps CI, pre-commit, and just in sync.
              '';
            };

            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pkgs.ty;
              defaultText = "config.jackpkgs.pkgs.ty";
              description = ''
                `ty` binary package for the pre-commit ty hook. Defaults to
                `config.jackpkgs.pkgs.ty` (nixpkgs). Distinct from
                `ty.environment`, which is the interpreter tree ty analyses.
              '';
            };
          };

          ruff = {
            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.ty.environment;
              defaultText = ''
                Follows the resolved `ty.environment` (shared dev-tools env or
                custom override), except it substitutes the standalone
                `config.jackpkgs.pkgs.ruff` whenever `ty.environment` resolves
                to the bare `config.jackpkgs.pkgs.ty` (which has no `ruff`
                executable) — whether via fallback or an explicit pin. Set this
                option directly to override.
              '';
              description = "ruff package (or Python environment containing ruff) to use.";
            };
          };

          pytest = {
            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.ty.environment;
              defaultText = "config.jackpkgs.pre-commit.python.ty.environment";
              description = "pytest package (or Python environment containing pytest) to use.";
            };
          };

          numpydoc = {
            package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.ty.environment;
              defaultText = "config.jackpkgs.pre-commit.python.ty.environment";
              description = ''
                Python package (or environment) that provides
                `python -m numpydoc.hooks.validate_docstrings`.
              '';
            };
          };

          notebook = {
            ipynb.ruff.package = mkOption {
              type = types.package;
              default = config.jackpkgs.pre-commit.python.ruff.package;
              defaultText = "config.jackpkgs.pre-commit.python.ruff.package";
              description = "ruff package to use for `.ipynb` notebook pre-commit hooks.";
            };

            myst.jupytextPackage = mkOption {
              type = types.package;
              default = pkgs.python313Packages.jupytext;
              defaultText = "pkgs.python313Packages.jupytext";
              description = "jupytext package to use for MyST-NB pre-commit hooks.";
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
            default = jackpkgsInputs.self.packages.${pkgs.stdenv.hostPlatform.system}."adr-conflict-check";
            defaultText = "jackpkgsInputs.self.packages.${pkgs.stdenv.hostPlatform.system}.\"adr-conflict-check\"";
            description = "The `adr-conflict-check` package to use.";
          };

          allowSkipped = mkOption {
            type = types.listOf types.str;
            default = [];
            example = ["017" "018" "024"];
            description = ''
              ADR numbers (zero-padded 3-digit strings) that are allowed to
              be missing from the sequence.  Use this to grandfather legacy
              gaps from before the hook was enforced, without creating
              tombstone placeholder ADRs.

              Each entry must be a valid 3-digit number (e.g. `"017"`).
              Passed as `--allow-skipped` to `adr-conflict-check`.
            '';
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

        # Explicit config wins if either the pre-commit-local option or the
        # checks-module option sets it; otherwise resolvePackages falls back
        # to pnpm-workspace.yaml auto-discovery (ADR-040).
        tscPackages = jackpkgsLib.resolvePackages {
          explicit =
            if sysCfg.typescript.tsc.packages != null
            then sysCfg.typescript.tsc.packages
            else lib.attrByPath ["typescript" "tsc" "packages"] null checksCfg;
          workspaceRoot = projectRoot;
          fromYAML = preCommitFromYAML;
        };

        vitestPackages = jackpkgsLib.resolvePackages {
          explicit =
            if sysCfg.javascript.vitest.packages != null
            then sysCfg.javascript.vitest.packages
            else lib.attrByPath ["vitest" "packages"] null checksCfg;
          workspaceRoot = projectRoot;
          fromYAML = preCommitFromYAML;
        };

        biomeNodeModules =
          if sysCfg.biome.lint.nodeModules != null
          then sysCfg.biome.lint.nodeModules
          else defaultNodeModules;

        biomePackages = jackpkgsLib.resolvePackages {
          explicit =
            if sysCfg.biome.lint.packages != null
            then sysCfg.biome.lint.packages
            else lib.attrByPath ["biome" "lint" "packages"] null checksCfg;
          workspaceRoot = projectRoot;
          fromYAML = preCommitFromYAML;
        };

        biomeLintEntry = lib.getExe (pkgs.writeShellApplication {
          name = "biome-lint-hook";
          runtimeInputs = lib.optionals (biomeNodeModules != null) [biomeNodeModules];
          text = ''
            ${lib.optionalString (biomeNodeModules != null) (jackpkgsLib.nodejs.mkWorkspaceRuntime {
              nodeModules = biomeNodeModules;
              workspaceRoot = projectRoot;
              packages = biomePackages;
            })}
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
          then
            lib.getExe (pkgs.writeShellApplication {
              name = "tsc-hook";
              runtimeInputs = [tscNodeModules];
              text = ''
                ${jackpkgsLib.nodejs.mkWorkspaceRuntime {
                  nodeModules = tscNodeModules;
                  workspaceRoot = projectRoot;
                  packages = tscPackages;
                }}
                ${lib.concatMapStringsSep "\n" (pkg: ''
                    (cd ${lib.escapeShellArg pkg} && "${tscExe}" --noEmit${escapeExtraArgs checksCfg.typescript.tsc.extraArgs})
                  '')
                  tscPackages}
              '';
            })
          else
            lib.getExe (pkgs.writeShellApplication {
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
            ${lib.optionalString (vitestNodeModules != null) (jackpkgsLib.nodejs.mkWorkspaceRuntime {
              nodeModules = vitestNodeModules;
              workspaceRoot = projectRoot;
              packages = vitestPackages;
            })}
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
        preCommitTyEnvironmentDefault = pythonEnvHelpers.selectDevToolsPackage {
          pythonCfg = jackpkgsPythonCfg;
          pythonWorkspace = config._module.args.pythonWorkspace or null;
          pythonEnvOutputs = let
            fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} moduleTop.config;
            fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} config;
          in
            fromFlake // fromSystem;
          # ADR 045 §6: the global `checks.python.environment` wins first, so
          # a single declaration steers checks, pre-commit, and just alike.
          # It is a per-system option, so read it from the per-system `config`.
          globalEnvironment = lib.attrByPath ["jackpkgs" "checks" "python" "environment"] null config;
          pythonDefaultEnv = let
            fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;
            fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null moduleTop.config;
          in
            if fromSystem != null
            then fromSystem
            else fromFlake;
          # A bare interpreter — for repos with no configured Python env this is
          # still a valid `ty --python` target (unlike the ty binary package).
          fallbackPackage = config.jackpkgs.pkgs.python3;
        };
        # ruff inherits the RESOLVED ty environment — a shared dev-tools env or a
        # custom `ty.environment` override — so the shared-env behavior is
        # preserved for any env that actually contains ruff. The one substitution
        # is when it resolves to the bare `python3` fallback: that interpreter has
        # no `ruff` executable (which would break the hook with "Executable ...
        # not found"), so ruff uses the standalone `pkgs.ruff` instead (mirrors
        # just.nix). This triggers whether the bare interpreter arrived via the
        # fallback OR an explicit `ty.environment = pkgs.python3` pin — correct
        # either way, since running ruff from a ruff-less package cannot work; pin
        # `ruff.package` directly to override. pytest/numpydoc keep inheriting
        # ty.environment unchanged (no standalone nixpkgs package; both off by
        # default).
        preCommitRuffPackageDefault = let
          tyEnv = config.jackpkgs.pre-commit.python.ty.environment;
        in
          if tyEnv == config.jackpkgs.pkgs.python3
          then config.jackpkgs.pkgs.ruff
          else tyEnv;
      in {
        jackpkgs.pre-commit.python.ty.environment = lib.mkDefault preCommitTyEnvironmentDefault;
        jackpkgs.pre-commit.python.ruff.package = lib.mkDefault preCommitRuffPackageDefault;
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

          settings.hooks.nbqa-ruff = {
            enable = checksCfg.python.notebook.ipynb.ruff.enable;
            package = sysCfg.nbqa.package;
            entry = let
              ruffExe = lib.getExe' sysCfg.python.notebook.ipynb.ruff.package "ruff";
              nbqaExe = lib.getExe' sysCfg.nbqa.package "nbqa";
            in "${nbqaExe} \"${ruffExe} check\" --nbqa-shell${escapeExtraArgs checksCfg.python.notebook.ipynb.ruff.extraArgs}";
            files = "\\.ipynb$";
            pass_filenames = false;
          };

          settings.hooks.jupytext-ruff = {
            enable = checksCfg.python.notebook.myst.ruff.enable && checksCfg.python.notebook.myst.ruff.includes != [];
            package = sysCfg.python.notebook.myst.jupytextPackage;
            entry = let
              jupytextExe = lib.getExe' sysCfg.python.notebook.myst.jupytextPackage "jupytext";
            in "${jupytextExe} --check \"ruff check${escapeExtraArgs checksCfg.python.notebook.myst.ruff.extraArgs} {}\" --pipe-fmt py:percent";
            files = "\\.md$";
            pass_filenames = true;
          };

          settings.hooks.ty = {
            enable = checksCfg.python.ty.enable;
            package = sysCfg.python.ty.package;
            # Run ty on the whole workspace (same scope as `just lint` / CI
            # checks) instead of per-staged-file.  When pass_filenames is true
            # (the default) pre-commit passes only the staged file paths, and
            # per-file analysis can't resolve the full type graph.
            pass_filenames = false;
            entry = let
              tyEnv = sysCfg.python.ty.environment;
              tyBin = lib.getExe sysCfg.python.ty.package;
            in
              lib.getExe (pkgs.writeShellApplication {
                name = "ty-hook";
                runtimeInputs = [sysCfg.python.ty.package];
                text = ''
                  "${tyBin}" check --python "${tyEnv}"${escapeExtraArgs checksCfg.python.ty.extraArgs} .
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

          settings.hooks.adr-conflict-check = {
            enable = sysCfg.adr.enable;
            package = sysCfg.adr.package;
            entry = "${lib.getExe sysCfg.adr.package} --adr-dir ${lib.escapeShellArg sysCfg.adr.directory}${lib.optionalString (sysCfg.adr.allowSkipped != []) " --allow-skipped ${lib.escapeShellArg (lib.concatStringsSep "," sysCfg.adr.allowSkipped)}"}";
            files = "\\.md$";
            pass_filenames = false;
          };
        };
      };
    }
  );
}
