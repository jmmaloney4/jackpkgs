{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  jackpkgsLib,
  ...
} @ moduleTop: let
  inherit (lib) mkOption types mkEnableOption;
  pythonEnvHelpers = import ../../lib/python-env-selection.nix {inherit lib;};
  cfg = config.jackpkgs.checks;
  pythonCfg = config.jackpkgs.python or {};
in {
  options = {
    jackpkgs.checks = {
      enable =
        mkEnableOption "jackpkgs CI checks"
        // {
          default =
            (config.jackpkgs.python.enable or false)
            || (config.jackpkgs.pulumi.enable or false)
            || (config.jackpkgs.nodejs.enable or false);
          description = ''
            Enable CI checks for jackpkgs projects. Automatically enabled when
            Python, Pulumi, or Node.js modules are enabled.
          '';
        };

      # Python ecosystem checks
      python = {
        enable =
          mkEnableOption "Python CI checks"
          // {
            default = config.jackpkgs.python.enable or false;
            description = ''
              Enable Python CI checks (pytest, ty, ruff). Automatically enabled when the
              Python module is enabled. numpydoc checks are opt-in; enable separately with
              `python.numpydoc.enable = true`.
            '';
          };

        environment = mkOption {
          type = types.nullOr types.package;
          default = null;
          defaultText = "null (falls through to the legacy dev-tools env chain)";
          description = ''
            Python environment that all Python CI checks (pytest, ty, ruff,
            numpydoc, notebook-ruff) resolve against when set (ADR 045).

            This is the single declarative source of truth for "which
            environment carries the quality-gate tools". It also steers the
            `pre-commit` and `just` tool-environment selection
            (`selectDevToolsPackage`), so one declaration keeps CI checks,
            pre-commit hooks, and `just` recipes in sync.

            Resolution per check: the per-check `.environment` (if set) wins,
            then this global option, then the legacy fallback chain
            (`config.jackpkgs.outputs.pythonDefaultEnv` → a dev-tools env
            selected from `jackpkgs.python.environments` → a synthesized
            all-groups env). Any check that falls through to the legacy chain
            emits an eval-time warning recommending this option.

            Typical value:
            `config.jackpkgs.outputs.pythonEnvironments.dev`.
          '';
        };

        pytest = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable pytest checks";
          };

          environment = mkOption {
            type = types.nullOr types.package;
            default = null;
            defaultText = "null (uses `checks.python.environment`, then the legacy chain)";
            description = ''
              Python environment the pytest check runs against, overriding
              `checks.python.environment` for pytest only. The selected
              derivation MUST provide a `pytest` executable.
            '';
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = ["--import-mode=importlib"];
            description = "Arguments to pass to pytest";
            example = ["--import-mode=importlib" "--color=yes" "-v"];
          };
        };

        ty = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable Python type checking with ty";
          };

          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            defaultText = "null (resolved to config.jackpkgs.pkgs.ty in perSystem)";
            description = ''
              [ty](https://github.com/astral-sh/ty) binary package (the type
              checker itself). Defaults to `config.jackpkgs.pkgs.ty` (nixpkgs)
              when null, resolved lazily in perSystem context. This is distinct
              from `ty.environment`, which is the interpreter/site-packages
              tree ty analyses via `--python`.
            '';
          };

          environment = mkOption {
            type = types.nullOr types.package;
            default = null;
            defaultText = "null (uses `checks.python.environment`, then the legacy chain)";
            description = ''
              Python environment ty resolves imports against (passed as
              `ty check --python <env>`), overriding
              `checks.python.environment` for the type check only.

              Unlike the other checks, this environment is NOT required to
              provide the checker binary — ty comes from `ty.package`. It only
              needs to be the interpreter/site-packages tree whose types ty
              should see.
            '';
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to ty";
            example = ["--error-on-warning"];
          };
        };

        # ADR 046 tombstones: mypy was removed and ty is the sole type
        # checker. These two paths are the only ones consumers were known to
        # set; they are declared hidden purely so a stale assignment fails
        # eval with actionable migration text (enforced in perSystem below).
        # Every other `mypy.*` path fails naturally as an unknown option.
        mypy = {
          typeChecker = mkOption {
            type = types.nullOr types.raw;
            default = null;
            visible = false;
            internal = true;
            description = "Removed in ADR 046 (tombstone). Use `checks.python.ty`.";
          };

          tyPackage = mkOption {
            type = types.nullOr types.raw;
            default = null;
            visible = false;
            internal = true;
            description = "Removed in ADR 046 (tombstone). Use `checks.python.ty.package`.";
          };
        };

        ruff = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable ruff linting";
          };

          environment = mkOption {
            type = types.nullOr types.package;
            default = null;
            defaultText = "null (uses `checks.python.environment`, then the legacy chain)";
            description = ''
              Python environment whose `ruff` binary is used for the ruff check
              and the notebook-ruff (nbqa / jupytext) checks, overriding
              `checks.python.environment` for linting only. Only the `ruff`
              executable is consulted from this environment.
            '';
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = ["--no-cache"];
            description = "Extra arguments to pass to ruff";
            example = ["--no-cache"];
          };
        };

        notebook = {
          ipynb.ruff = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable notebook linting for Jupyter `.ipynb` files using `nbqa ruff check`.
              '';
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = ["--no-cache"];
              description = "Extra arguments to pass to `ruff check` via nbqa";
              example = ["--no-cache"];
            };

            includes = mkOption {
              type = types.listOf types.str;
              default = ["*.ipynb"];
              description = "File patterns to include for `.ipynb` notebook checks.";
            };
          };

          myst.ruff = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable notebook linting for MyST-NB markdown notebooks using jupytext and `ruff check`.
              '';
            };

            extraArgs = mkOption {
              type = types.listOf types.str;
              default = ["--no-cache"];
              description = "Extra arguments to pass to `ruff check` for MyST notebooks";
              example = ["--no-cache"];
            };

            includes = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''File patterns to include for MyST-NB checks. Users SHOULD configure explicitly.'';
              example = ["docs/**/*.md"];
            };
          };
        };

        numpydoc = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable numpydoc docstring validation.

              Disabled by default; opt in with
              `jackpkgs.checks.python.numpydoc.enable = true;`.

              Requires `numpydoc` to be available in the selected Python check
              environment.
            '';
          };

          environment = mkOption {
            type = types.nullOr types.package;
            default = null;
            defaultText = "null (uses `checks.python.environment`, then the legacy chain)";
            description = ''
              Python environment to run numpydoc from, overriding
              `checks.python.environment` for the numpydoc check only.

              The selected derivation must provide a `python` executable that
              can import `numpydoc.hooks.validate_docstrings`. Set this when
              numpydoc lives in a dependency group deliberately excluded from
              the lean CI check env (e.g. a `research` or `docs` group), so the
              check can use a richer environment without pulling the extra deps
              into pytest/ty/ruff.
            '';
          };

          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            visible = false;
            description = ''
              Deprecated alias of `checks.python.numpydoc.environment` (ADR
              045). Still honored when set — with an eval-time warning — but
              prefer `.environment`. When both are set, `.environment` wins.
            '';
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to numpydoc.hooks.validate_docstrings";
            example = ["--checks" "all"];
          };
        };
      };

      # Injectable YAML parser (for testing without IFD)
      fromYAML = mkOption {
        type = types.nullOr (types.functionTo types.attrs);
        default = null;
        internal = true;
        description = "YAML parser function. Defaults to IFD-based yq-go parser.";
      };

      # TypeScript ecosystem checks
      typescript.tsc = {
        enable = mkOption {
          type = types.bool;
          default = config.jackpkgs.nodejs.enable or false;
          description = ''
            Enable TypeScript type checking with tsc. Automatically enabled
            when the Node.js module is enabled.
          '';
        };

        nodeModules = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = ''
            Derivation containing the `node_modules` structure to link before running checks.
            Typically provided automatically by `jackpkgs.nodejs`.

            When null, falls back to config.jackpkgs.outputs.nodeModules if available.
          '';
        };

        packages = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = ''
            List of packages to type-check.

            RECOMMENDED: Explicitly list packages for reliability and clarity.
            Example: packages = ["infra" "tools/hello" "apps/web"];

            If null, packages will be auto-discovered from pnpm-workspace.yaml
            "packages" field. Auto-discovery supports simple wildcard patterns
            (e.g. "packages/*") but does NOT support full recursive globs
            (e.g. "packages/**").

            For complex workspace configurations, use explicit listing.
          '';
          example = ["infra" "tools/hello"];
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra arguments to pass to tsc";
          example = ["--strict"];
        };
      };

      # Biome lint check
      # Note: Biome formatting is handled separately by the `fmt` module via treefmt.
      # This check runs `biome lint` (lint only, no format enforcement) from the
      # workspace root.
      biome.lint = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable Biome lint checks. Disabled by default; opt in with
            `jackpkgs.checks.biome.lint.enable = true;`.

            Runs `biome lint` from the workspace root. Biome formatting is handled
            separately by the `fmt` module (treefmt); this check is lint-only to
            avoid duplicate reporting.
          '';
        };

        nodeModules = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = ''
            Derivation containing the `node_modules` structure (and the `biome`
            binary within it) to link before running checks.

            When null, falls back to `config.jackpkgs.outputs.nodeModules` if
            available.
          '';
        };

        packages = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = ''
            List of workspace packages to lint.

            If null, packages will be auto-discovered from pnpm-workspace.yaml,
            matching the same default as `typescript.tsc.packages`.
          '';
          example = ["infra" "tools/hello"];
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra arguments to pass to `biome lint`";
          example = ["--reporter=github"];
        };
      };

      # Vitest check
      vitest = {
        enable =
          mkEnableOption "Vitest CI checks"
          // {
            default = config.jackpkgs.nodejs.enable or false;
            description = ''
              Enable Vitest test runner. Automatically enabled when the Node.js module is enabled.
            '';
          };

        nodeModules = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = ''
            Derivation containing the `node_modules` structure to link before running checks.
            Typically provided automatically by `jackpkgs.nodejs`.

            When null, falls back to config.jackpkgs.outputs.nodeModules if available.
          '';
        };

        packages = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = ''
            List of packages to test with Vitest.
            If null, uses same discovery as tsc (pnpm-workspace.yaml).
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra arguments to pass to Vitest";
          example = ["--coverage" "--reporter=verbose"];
        };
      };

      beancount = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to run bean-check on the beancount ledger.
            Disabled by default; must be explicitly opted in.
            Requires jackpkgs.python.enable = true and a configured ledgerFile.
          '';
        };

        ledgerFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Path to the main beancount ledger file
            (e.g., ./books/beancount/ledger/main.beancount).
            The entire parent directory is copied to the Nix store so that
            include directives and glob patterns in the ledger resolve correctly.
            Required when jackpkgs.checks.beancount.enable = true.
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra arguments to pass to bean-check.";
        };
      };

      # Shell script checks
      shell = {
        enable =
          mkEnableOption "Shell script CI checks (shellcheck, actionlint, bashate)"
          // {
            default = false;
            description = ''
              Enable shell script CI checks. Disabled by default; opt in with
              `jackpkgs.checks.shell.enable = true;`.
            '';
          };

        shellcheck = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable ShellCheck linting of shell scripts";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to shellcheck";
          };
        };

        actionlint = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable actionlint for GitHub Actions workflows";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to actionlint";
          };
        };

        bashate = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable bashate style checks for shell scripts.
              Disabled by default; opt in with
              `jackpkgs.checks.shell.bashate.enable = true;`.
            '';
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to bashate (e.g. [\"-E\", \"E006\"] to ignore rule E006)";
          };
        };
      };

      # Future: golang, rust, etc. can be added here
    };
  };

  config = {
    perSystem = {
      pkgs,
      lib,
      config,
      pythonWorkspace ? null,
      jackpkgsProjectRoot ? null,
      jackpkgsFromYAML ? null,
      ...
    }: let
      # ============================================================
      # Helper Functions
      # ============================================================
      # jackpkgsLibFull extends jackpkgsLib (nodejs-helpers) with pkgs-aware
      # helpers from lib/default.nix (mkFromYAML, etc.) that need pkgs at
      # evaluation time.
      jackpkgsLibFull =
        jackpkgsLib // (import ../../lib {inherit pkgs;});

      # Use the shared mkFromYAML from jackpkgsLibFull (with JSON-sidecar
      # optimisation enabled: if a .json file exists beside the .yaml/.yml it
      # is read directly, avoiding an IFD build for each evaluation).
      fromYAML =
        if cfg.fromYAML != null
        then cfg.fromYAML
        else jackpkgsLibFull.mkFromYAML {jsonSidecar = true;};

      discoverPnpmPackages = workspaceRoot:
        jackpkgsLib.discoverPnpmPackages {
          inherit workspaceRoot fromYAML;
        };

      # Node.js runtime with safe fallback: prefer jackpkgs.nodejs.package,
      # then jackpkgs.pkgs.nodejs_24 (respects overlays), then pkgs.nodejs_24.
      nodejsPackage =
        lib.attrByPath ["jackpkgs" "nodejs" "package"]
        (lib.attrByPath ["jackpkgs" "pkgs" "nodejs_24"] pkgs.nodejs_24 config)
        config;

      # Generic check factory
      #
      # When `src` is set, it is passed as a derivation attribute so Nix tracks
      # the source as a proper input (available in the sandbox).  The builder
      # then `cd`s into `$src` — using the env-var expansion avoids
      # interpolating the bare store path into the command string, which would
      # produce "without a proper context" warnings and fail under
      # sandboxed builds (Nix ≥ 2.33).
      mkCheck = {
        name,
        buildInputs ? [],
        nativeBuildInputs ? [],
        src ? null,
        setupCommands ? "",
        checkCommands,
      }:
        pkgs.runCommand name ({
            inherit buildInputs nativeBuildInputs;
          }
          // lib.optionalAttrs (src != null) {inherit src;}) ''
          ${lib.optionalString (src != null) ''cd "$src"''}
          ${setupCommands}
          ${checkCommands}
          touch $out
        '';

      linkNodeModules = nodeModules: packages:
        if nodeModules == null
        then ""
        else ''
          echo "Linking node_modules from ${toString nodeModules}..."
          ${jackpkgsLib.nodejs.mkWorkspaceRuntime {
            inherit nodeModules packages;
            workspaceRoot = projectRoot;
          }}
        '';

      # ============================================================
      # Python Workspace Discovery
      # ============================================================

      pythonPerSystemCfg = config.jackpkgs.python or {};
      pythonWorkspaceArg = pythonWorkspace;

      # Shared workspace-path helpers (ADR-041: single source of truth for
      # Python workspace member discovery and source-root derivation).
      pythonWorkspacePaths = import ../../lib/python-workspace-paths.nix {inherit lib;};

      # Discover workspace members if Python module is enabled
      pythonWorkspaceMembers =
        if pythonCfg.enable or false && pythonCfg ? workspaceRoot && pythonCfg ? pyprojectPath && pythonCfg.workspaceRoot != null && pythonCfg.pyprojectPath != null
        then let
          validatedPath = jackpkgsLib.validateWorkspacePath pythonCfg.pyprojectPath;
          resolvedPyprojectPath = pythonCfg.workspaceRoot + "/${validatedPath}";
        in
          pythonWorkspacePaths.discoverPythonWorkspaceMembers {
            workspaceRoot = pythonCfg.workspaceRoot;
            pyprojectPath = resolvedPyprojectPath;
          }
        else [];

      # Build Python environment with dev tools for CI checks using the
      # shared helper to keep checks and pre-commit selection in sync.
      pythonEnvWithDevTools = pythonEnvHelpers.selectPythonEnvWithDevTools {
        inherit pythonCfg;
        pythonWorkspace = pythonWorkspaceArg;
        pythonEnvOutputs = config.jackpkgs.outputs.pythonEnvironments or {};
      };

      # Prefer the consumer project's configured default Python env when available.
      # This typically includes dev tools (pytest/ty/ruff) via the workspace spec.
      jackpkgsOutputs = config.jackpkgs.outputs or {};
      pythonDefaultEnv = let
        fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;
        fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null moduleTop.config;
      in
        if fromSystem != null
        then fromSystem
        else fromFlake;

      # ADR 045 legacy fallback chain (unchanged ordering): the historical
      # selection used when neither a per-check `.environment` nor the global
      # `checks.python.environment` is set.
      legacyEnvForChecks =
        if pythonDefaultEnv != null
        then pythonDefaultEnv
        else pythonEnvWithDevTools;

      # Env used solely to decide whether Python checks can be emitted at all.
      # No warning here — the noisy legacy-fallback warning is reserved for the
      # per-check resolver so it fires once per check that actually builds.
      baseCheckEnv =
        if cfg.python.environment != null
        then cfg.python.environment
        else legacyEnvForChecks;

      # ADR 045 §3: resolve one check's environment.
      #   per-check `.environment` → global `checks.python.environment` → legacy chain.
      # Falling through to the legacy chain warns, recommending the explicit option.
      resolveCheckEnv = checkName: perCheckEnv:
        if perCheckEnv != null
        then perCheckEnv
        else if cfg.python.environment != null
        then cfg.python.environment
        else
          lib.warn ''
            jackpkgs: the '${checkName}' Python check is resolving its environment via the legacy fallback chain (pythonDefaultEnv → dev-tools env → synthesized all-groups env). Set `jackpkgs.checks.python.environment` (or `checks.python.${checkName}.environment`) to select it explicitly; the legacy chain is deprecated.
          ''
          legacyEnvForChecks;

      # ADR 045 §9: derive the Python X.Y from a specific environment so
      # PYTHONPATH matches the interpreter that runs that check's tool.
      pythonVersionOf = env:
        if env != null && (env ? pythonVersion)
        then env.pythonVersion
        else if pythonPerSystemCfg ? pythonPackage && pythonPerSystemCfg.pythonPackage != null
        then pythonPerSystemCfg.pythonPackage.pythonVersion
            or (lib.versions.majorMinor (pythonPerSystemCfg.pythonPackage.version or "3.12"))
        else "3.12";

      # ADR 046 tombstone enforcement: fail eval (with migration text) if a
      # removed mypy option is still set. Forced via `builtins.seq` at the
      # bottom of this perSystem so the throw always fires.
      mypyRemovalError =
        if cfg.python.mypy.typeChecker != null
        then throw "jackpkgs: `jackpkgs.checks.python.mypy.typeChecker` was removed in ADR 046 — mypy support is gone and ty is the only type checker. Delete this option (a prior `\"ty\"` value is now the default) and move any `checks.python.mypy.extraArgs` to `checks.python.ty.extraArgs`."
        else if cfg.python.mypy.tyPackage != null
        then throw "jackpkgs: `jackpkgs.checks.python.mypy.tyPackage` was renamed to `jackpkgs.checks.python.ty.package` in ADR 046. Move your ty binary package there."
        else null;

      # ============================================================
      # TypeScript Workspace Discovery
      # ============================================================

      projectRoot =
        if jackpkgsProjectRoot != null
        then jackpkgsProjectRoot
        else config.jackpkgs.projectRoot or inputs.self.outPath;

      # Lazy package discovery - only compute when actually needed
      # This avoids IFD during module evaluation when checks aren't generated
      getTsPackages = cfg':
        if cfg'.typescript.tsc.packages != null
        then map jackpkgsLib.validateWorkspacePath cfg'.typescript.tsc.packages
        else discoverPnpmPackages projectRoot;

      getVitestPackages = cfg':
        if cfg'.vitest.packages != null
        then map jackpkgsLib.validateWorkspacePath cfg'.vitest.packages
        else discoverPnpmPackages projectRoot;

      # NOTE: We cannot use builtins.pathExists on nodeModules paths at Nix evaluation
      # time because the derivation doesn't exist yet (it's built later). The path
      # existence checks must happen at runtime (in the shell script) when the
      # derivation has actually been built.

      # ============================================================
      # Python Checks
      # ============================================================

      pythonChecks = let
        # Per-check resolved environments (ADR 045 §3).
        pytestEnv = resolveCheckEnv "pytest" cfg.python.pytest.environment;
        tyEnv = resolveCheckEnv "ty" cfg.python.ty.environment;
        ruffEnv = resolveCheckEnv "ruff" cfg.python.ruff.environment;
        # ADR 045 §4: notebook-ruff (nbqa / jupytext) follows ruff.environment.
        notebookEnv = ruffEnv;
        # ADR 045 §5: numpydoc.environment → deprecated numpydoc.package (warn)
        # → global → legacy `pythonEnvironments.dev` preference → legacy chain.
        numpydocEnv =
          if cfg.python.numpydoc.environment != null
          then cfg.python.numpydoc.environment
          else if cfg.python.numpydoc.package != null
          then lib.warn "jackpkgs: `checks.python.numpydoc.package` is a deprecated alias of `checks.python.numpydoc.environment` (ADR 045); rename it." cfg.python.numpydoc.package
          else if cfg.python.environment != null
          then cfg.python.environment
          else jackpkgsOutputs.pythonEnvironments.dev
            or (lib.warn "jackpkgs: the 'numpydoc' Python check is resolving its environment via the legacy fallback chain. Set `jackpkgs.checks.python.environment` or `checks.python.numpydoc.environment`." legacyEnvForChecks);

        # ty binary (distinct from tyEnv, the `--python` resolution target).
        tyBin =
          if cfg.python.ty.package != null
          then cfg.python.ty.package
          else config.jackpkgs.pkgs.ty;

        # ruff binary comes from the resolved ruff env.
        nbqaRuffExe = lib.getExe' ruffEnv "ruff";
        nbqaPackage = pkgs.nbqa;
        jupytextPackage = pkgs.python313Packages.jupytext;

        # ADR 045 §8: fail fast with an actionable message when the resolved
        # environment is missing the executable a check needs.
        mkToolGuard = {
          env,
          tool,
          checkName,
          hint,
        }: ''
          if [ ! -x "${env}/bin/${tool}" ]; then
            printf '%s\n' \
              "ERROR: jackpkgs '${checkName}' check: '${tool}' not found in the resolved Python environment." \
              "  environment: ${env}" \
              "  ${hint}" >&2
            exit 1
          fi
        '';
      in
        lib.optionalAttrs (cfg.enable && cfg.python.enable && baseCheckEnv != null && pythonWorkspaceMembers != [])
        (
          lib.optionalAttrs cfg.python.pytest.enable {
            # pytest check (workspace root)
            pytest = mkCheck {
              name = "pytest";
              src = pythonCfg.workspaceRoot;
              nativeBuildInputs = [pytestEnv];
              setupCommands = ''
                ${mkToolGuard {
                  env = pytestEnv;
                  tool = "pytest";
                  checkName = "pytest";
                  hint = "Add pytest to that environment's dependency groups, or set `checks.python.pytest.environment` (or `checks.python.environment`) to an env that provides it.";
                }}
                export PYTHONPATH="${pytestEnv}/lib/python${pythonVersionOf pytestEnv}/site-packages"
                export COVERAGE_FILE=$TMPDIR/.coverage
                export PYTEST_CACHE_DIR=$TMPDIR/.pytest_cache
                # Unset SSL_CERT_FILE so httpx/langfuse/litellm don't try to
                # load a CA bundle that doesn't exist in the Nix sandbox.
                # Tests are mocked and never make real TLS connections.
                export SSL_CERT_FILE=""
              '';
              checkCommands = ''
                echo "Running pytest (workspace root)..."
                "${lib.getExe' pytestEnv "pytest"}" ${lib.escapeShellArgs cfg.python.pytest.extraArgs}
              '';
            };
          }
          // lib.optionalAttrs cfg.python.ty.enable {
            # Python type-check with ty (workspace root)
            ty = mkCheck {
              name = "ty";
              src = pythonCfg.workspaceRoot;
              buildInputs = [tyBin];
              nativeBuildInputs = [tyEnv];
              setupCommands = mkToolGuard {
                # The ty binary comes from `ty.package`; the resolved
                # environment is only ty's `--python` target and is NOT
                # required to provide ty itself (ADR 045 §8).
                env = tyBin;
                tool = "ty";
                checkName = "ty";
                hint = "Set `checks.python.ty.package` to a package that provides the ty binary.";
              };
              checkCommands = ''
                echo "Running ty check (workspace root)..."
                ty check --python ${tyEnv} ${lib.escapeShellArgs cfg.python.ty.extraArgs} .
              '';
            };
          }
          // lib.optionalAttrs cfg.python.ruff.enable {
            # ruff check (workspace root)
            ruff = mkCheck {
              name = "ruff";
              src = pythonCfg.workspaceRoot;
              nativeBuildInputs = [ruffEnv];
              setupCommands = ''
                ${mkToolGuard {
                  env = ruffEnv;
                  tool = "ruff";
                  checkName = "ruff";
                  hint = "Add ruff to that environment's dependency groups, or set `checks.python.ruff.environment` (or `checks.python.environment`) to an env that provides it.";
                }}
                export RUFF_CACHE_DIR=$TMPDIR/.ruff_cache
              '';
              checkCommands = ''
                echo "Running ruff check (workspace root)..."
                "${lib.getExe' ruffEnv "ruff"}" check ${lib.escapeShellArgs cfg.python.ruff.extraArgs} .
              '';
            };
          }
          // lib.optionalAttrs cfg.python.notebook.ipynb.ruff.enable {
            python-notebook-ipynb-ruff = mkCheck {
              name = "python-notebook-ipynb-ruff";
              src = pythonCfg.workspaceRoot;
              nativeBuildInputs = [notebookEnv pkgs.fd nbqaPackage];
              setupCommands = ''
                ${mkToolGuard {
                  env = notebookEnv;
                  tool = "ruff";
                  checkName = "python-notebook-ipynb-ruff";
                  hint = "The notebook-ruff check follows `checks.python.ruff.environment`; add ruff there.";
                }}
                export RUFF_CACHE_DIR=$TMPDIR/.ruff_cache
              '';
              checkCommands = ''
                echo "Running nbqa ruff check (workspace root)..."
                mapfile -t notebook_files < <(
                  ${lib.concatMapStringsSep "\n" (pattern: ''fd -t f --glob ${lib.escapeShellArg pattern} .'') cfg.python.notebook.ipynb.ruff.includes}
                )
                if [ "''${#notebook_files[@]}" -eq 0 ]; then
                  echo "No .ipynb notebooks matched; skipping."
                  exit 0
                fi
                "${lib.getExe nbqaPackage}" "${nbqaRuffExe} check" --nbqa-shell ${lib.escapeShellArgs cfg.python.notebook.ipynb.ruff.extraArgs} -- "''${notebook_files[@]}"
              '';
            };
          }
          // lib.optionalAttrs (cfg.python.notebook.myst.ruff.enable && cfg.python.notebook.myst.ruff.includes != []) {
            python-notebook-myst-ruff = mkCheck {
              name = "python-notebook-myst-ruff";
              src = pythonCfg.workspaceRoot;
              nativeBuildInputs = [notebookEnv pkgs.fd jupytextPackage];
              setupCommands = ''
                ${mkToolGuard {
                  env = notebookEnv;
                  tool = "ruff";
                  checkName = "python-notebook-myst-ruff";
                  hint = "The notebook-ruff check follows `checks.python.ruff.environment`; add ruff there.";
                }}
                export RUFF_CACHE_DIR=$TMPDIR/.ruff_cache
              '';
              checkCommands = ''
                echo "Running jupytext ruff check (workspace root)..."
                mapfile -t myst_notebook_files < <(
                  ${lib.concatMapStringsSep "\n" (pattern: ''fd -t f --glob ${lib.escapeShellArg pattern} .'') cfg.python.notebook.myst.ruff.includes}
                )
                if [ "''${#myst_notebook_files[@]}" -eq 0 ]; then
                  echo "No MyST notebooks matched; skipping."
                  exit 0
                fi
                "${lib.getExe jupytextPackage}" --check "${nbqaRuffExe} check ${lib.escapeShellArgs cfg.python.notebook.myst.ruff.extraArgs} {}" --pipe-fmt py:percent "''${myst_notebook_files[@]}"
              '';
            };
          }
          // lib.optionalAttrs cfg.python.numpydoc.enable {
            # numpydoc check (workspace root)
            numpydoc = mkCheck {
              name = "numpydoc";
              src = pythonCfg.workspaceRoot;
              nativeBuildInputs = [numpydocEnv];
              setupCommands = ''
                ${mkToolGuard {
                  env = numpydocEnv;
                  tool = "python";
                  checkName = "numpydoc";
                  hint = "The resolved env must provide a python that can import numpydoc; set `checks.python.numpydoc.environment` to an env that includes numpydoc.";
                }}
                export PYTHONPATH="${numpydocEnv}/lib/python${pythonVersionOf numpydocEnv}/site-packages"
              '';
              checkCommands = ''
                echo "Running numpydoc (workspace root)..."
                python -m numpydoc.hooks.validate_docstrings ${lib.escapeShellArgs cfg.python.numpydoc.extraArgs} .
              '';
            };
          }
        );

      # ============================================================
      # TypeScript Checks
      # ============================================================

      typescriptChecks = let
        tsPackages = getTsPackages cfg;
      in
        lib.optionalAttrs (cfg.enable && cfg.typescript.tsc.enable && tsPackages != []) {
          # tsc check
          tsc = mkCheck {
            name = "tsc";
            buildInputs = [nodejsPackage config.jackpkgs.pkgs.typescript];
            setupCommands = ''
              # Copy source to writeable directory
              cp -R ${projectRoot} src
              chmod -R +w src
              cd src
              ${linkNodeModules (
                  if cfg.typescript.tsc.nodeModules != null
                  then cfg.typescript.tsc.nodeModules
                  else config.jackpkgs.outputs.nodeModules or null
                )
                tsPackages}
              ${jackpkgsLib.mkWorkspaceSymlinks projectRoot tsPackages}
            '';
            checkCommands = ''
              # Validate node_modules exists before running.
              # Allow per-package node_modules (linked by linkNodeModules) as alternative.
              if [ ! -d "node_modules" ] && [ ! -d ${lib.escapeShellArg "${lib.head tsPackages}/node_modules"} ]; then
                printf '%s\n' \
                  "ERROR: node_modules not found." \
                  "" \
                  "TypeScript checks require node_modules to be present." \
                  "" \
                  "Enable the Node.js module to provide node_modules for checks:" \
                  "" \
                  "    jackpkgs.nodejs.enable = true;" \
                  "" \
                  "This provides a pure, reproducible node_modules derivation that works" \
                  "in Nix sandbox builds." \
                  "" \
                  "To disable TypeScript checks: jackpkgs.checks.typescript.tsc.enable = false;" \
                  >&2
                exit 1
              fi
              echo "Type-checking (workspace root)..."
              tsc --noEmit ${lib.escapeShellArgs cfg.typescript.tsc.extraArgs}
            '';
          };
        };

      # ============================================================
      # Vitest Checks
      # ============================================================

      vitestNodeModules =
        if cfg.vitest.nodeModules != null
        then cfg.vitest.nodeModules
        else config.jackpkgs.outputs.nodeModules or null;

      vitestChecks = let
        vitestPackages = getVitestPackages cfg;
      in
        lib.optionalAttrs (cfg.enable && cfg.vitest.enable && vitestPackages != []) {
          vitest = mkCheck {
            name = "vitest";
            buildInputs = [nodejsPackage];
            setupCommands = ''
              # Copy source to writeable directory
              cp -R ${projectRoot} src
              chmod -R +w src
              cd src
              ${linkNodeModules vitestNodeModules vitestPackages}

              # Save root directory for absolute path resolution
              WORKSPACE_ROOT="$PWD"
              export WORKSPACE_ROOT
              ${lib.optionalString (vitestNodeModules != null) ''
                # Add Nix store node_modules binaries to PATH
                ${jackpkgsLib.nodejs.findNodeModulesBin "nm_bin" vitestNodeModules}
                if [ -n "$nm_bin" ]; then
                  export PATH="$nm_bin:$PATH"
                fi
              ''}

              # Locate vitest binary from trusted sources only (once for all packages)
              # 1. PATH (includes Nix store paths from nodeModules derivation)
              # 2. Linked node_modules from Nix store (never from source tree)
              if command -v vitest >/dev/null 2>&1; then
                VITEST_BIN="$(command -v vitest)"
              else
                echo "ERROR: vitest binary not found in PATH." >&2
                echo "Ensure vitest is listed as a devDependency and nodeModules is provided." >&2
                exit 1
              fi
              export VITEST_BIN
            '';
            checkCommands = ''
              echo "Testing (workspace root)..."
              "$VITEST_BIN" ${lib.escapeShellArgs cfg.vitest.extraArgs} ${lib.escapeShellArgs vitestPackages}
            '';
          };
        };
      # ============================================================
      # Biome Lint Checks
      # ============================================================

      biomeNodeModules =
        if cfg.biome.lint.nodeModules != null
        then cfg.biome.lint.nodeModules
        else config.jackpkgs.outputs.nodeModules or null;

      getBiomePackages = cfg':
        if cfg'.biome.lint.packages != null
        then map jackpkgsLib.validateWorkspacePath cfg'.biome.lint.packages
        else discoverPnpmPackages projectRoot;

      biomeChecks = let
        biomePackages = getBiomePackages cfg;
      in
        lib.optionalAttrs (cfg.enable && cfg.biome.lint.enable && biomePackages != []) {
          biome-lint = mkCheck {
            name = "biome-lint";
            buildInputs = [nodejsPackage];
            setupCommands = ''
              # Copy source to writeable directory
              cp -R ${projectRoot} src
              chmod -R +w src
              cd src
              ${linkNodeModules biomeNodeModules biomePackages}
              ${jackpkgsLib.mkWorkspaceSymlinks projectRoot biomePackages}
              ${lib.optionalString (biomeNodeModules != null) ''
                # Add Nix store node_modules binaries (including biome) to PATH
                ${jackpkgsLib.nodejs.findNodeModulesBin "nm_bin" biomeNodeModules}
                if [ -n "$nm_bin" ]; then
                  export PATH="$nm_bin:$PATH"
                fi
              ''}
              # Locate biome binary
              if command -v biome >/dev/null 2>&1; then
                BIOME_BIN="biome"
              else
                printf '%s\n' \
                  "ERROR: biome binary not found for lint check." \
                  "" \
                  "Enable the Node.js module so that biome is available in node_modules:" \
                  "" \
                  "    jackpkgs.nodejs.enable = true;" \
                  "" \
                  "Or set a custom node_modules derivation:" \
                  "" \
                  "    jackpkgs.checks.biome.lint.nodeModules = <derivation>;" \
                  "" \
                  "To disable Biome lint checks: jackpkgs.checks.biome.lint.enable = false;" \
                  >&2
                exit 1
              fi
              export BIOME_BIN
            '';
            checkCommands = ''
              echo "Linting (workspace root)..."
              "$BIOME_BIN" lint ${lib.escapeShellArgs cfg.biome.lint.extraArgs} ${lib.escapeShellArgs biomePackages}
            '';
          };
        };
      beancountChecks =
        lib.optionalAttrs (cfg.enable
          && cfg.beancount.enable
          && cfg.beancount.ledgerFile != null
          && pythonEnvWithDevTools != null)
        {
          bean-check = mkCheck {
            name = "bean-check";
            buildInputs = [pythonEnvWithDevTools];
            setupCommands = ''
              # Copy the entire ledger directory so that include directives
              # and glob patterns in the ledger file resolve correctly.
              cp -R ${lib.escapeShellArg (builtins.dirOf cfg.beancount.ledgerFile)} ledger
              chmod -R +w ledger
              cd ledger
            '';
            checkCommands = ''
              bean-check ${lib.escapeShellArgs cfg.beancount.extraArgs} \
                ${lib.escapeShellArg (builtins.baseNameOf cfg.beancount.ledgerFile)}
            '';
          };
        };

      # ============================================================
      # Shell Script Checks
      # ============================================================

      shellChecks = lib.optionalAttrs (cfg.enable && cfg.shell.enable) (
        lib.optionalAttrs cfg.shell.shellcheck.enable {
          shellcheck = mkCheck {
            name = "shellcheck";
            src = projectRoot;
            buildInputs = [pkgs.shellcheck pkgs.fd];
            checkCommands = ''
              fd -t f --hidden '.*\.sh$|.*\.bash$|^\.envrc$' \
                -X shellcheck ${lib.escapeShellArgs cfg.shell.shellcheck.extraArgs}
            '';
          };
        }
        // lib.optionalAttrs cfg.shell.actionlint.enable {
          actionlint = mkCheck {
            name = "actionlint";
            src = projectRoot;
            buildInputs = [pkgs.actionlint pkgs.fd];
            checkCommands = ''
              test -d .github/workflows \
                && fd -t f --hidden -e yml -e yaml . .github/workflows/ \
                -X actionlint ${lib.escapeShellArgs cfg.shell.actionlint.extraArgs}
            '';
          };
        }
        // lib.optionalAttrs cfg.shell.bashate.enable {
          bashate = mkCheck {
            name = "bashate";
            src = projectRoot;
            buildInputs = [pkgs.bashate pkgs.fd];
            checkCommands = ''
              fd -t f --hidden '.*\.sh$|.*\.bash$|^\.envrc$' \
                -X bashate ${lib.escapeShellArgs cfg.shell.bashate.extraArgs}
            '';
          };
        }
      );
    in
      # `builtins.seq mypyRemovalError` forces the ADR 046 tombstone guard so a
      # stale `checks.python.mypy.typeChecker`/`tyPackage` fails eval whenever
      # this perSystem config is evaluated (e.g. `nix flake check`).
      builtins.seq mypyRemovalError
      # Merge all checks into the checks attribute
      (lib.mkMerge [
        {checks = pythonChecks;}
        {checks = typescriptChecks;}
        {checks = vitestChecks;}
        {checks = biomeChecks;}
        {checks = beancountChecks;}
        {checks = shellChecks;}
      ]);
  };
}
