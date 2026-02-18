{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  jackpkgsLib,
  ...
}: let
  inherit (lib) mkOption types mkEnableOption;
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
              Enable Python CI checks (pytest, mypy, ruff). Automatically enabled
              when the Python module is enabled.
            '';
          };

        pytest = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable pytest checks";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to pytest";
            example = ["--color=yes" "-v"];
          };
        };

        mypy = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable mypy type checking";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to mypy";
            example = ["--strict"];
          };
        };

        ruff = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable ruff linting";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = ["--no-cache"];
            description = "Extra arguments to pass to ruff";
            example = ["--no-cache"];
          };
        };
      };

      # TypeScript ecosystem checks
      typescript = {
        enable =
          mkEnableOption "TypeScript CI checks"
          // {
            default = config.jackpkgs.pulumi.enable or false;
            description = ''
              Enable TypeScript CI checks (tsc). Automatically enabled when the
              Pulumi module is enabled.
            '';
          };

        tsc = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable TypeScript type checking with tsc";
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
      ...
    }: let
      # ============================================================
      # Helper Functions
      # ============================================================

      # IFD helper: Parse YAML to JSON using yq-go
      # Used for pnpm-workspace.yaml parsing
      fromYAML = yamlFile: let
        jsonDrv = pkgs.runCommand "yaml-to-json" {
          nativeBuildInputs = [pkgs.yq-go];
        } ''
          yq -o=json '.' ${yamlFile} > $out
        '';
      in
        builtins.fromJSON (builtins.readFile jsonDrv);

      # Discover packages from pnpm-workspace.yaml
      discoverPnpmPackages = workspaceRoot: let
        yamlPath = workspaceRoot + "/pnpm-workspace.yaml";
        yamlExists = builtins.pathExists yamlPath;
        workspaceYaml =
          if yamlExists
          then fromYAML yamlPath
          else {};
        patterns = workspaceYaml.packages or [];
        workspaceGlobs =
          if builtins.isList patterns
          then patterns
          else [];
        allPackages = lib.flatten (map (jackpkgsLib.expandWorkspaceGlob workspaceRoot) workspaceGlobs);
        hasPackageJson = pkg:
          builtins.pathExists (workspaceRoot + "/${pkg}/package.json");
      in
        if yamlExists
        then lib.filter hasPackageJson allPackages
        else [];

      # Generic check factory
      mkCheck = {
        name,
        buildInputs ? [],
        setupCommands ? "",
        checkCommands,
      }:
        pkgs.runCommand name {inherit buildInputs;} ''
          ${setupCommands}
          ${checkCommands}
          touch $out
        '';

      # Generic workspace member iterator
      forEachWorkspaceMember = {
        workspaceRoot,
        members,
        perMemberCommand,
      }:
        lib.concatMapStringsSep "\n" (member: ''
          echo "Checking ${member}..."
          (cd ${lib.escapeShellArg "${workspaceRoot}/${member}"} && ${perMemberCommand})
        '')
        members;



      # Link node_modules into the sandbox
      # Strategy: Link root node_modules, then iterate through packages and link their
      # node_modules if present in the store (primarily for legacy dream2nix layouts).
      #
      # Supported layouts:
      # - buildNpmPackage: <store>/node_modules
      # - dream2nix (nodejs-granular): <store>/lib/node_modules/default/node_modules
      # - dream2nix (npm wrapper): <store>/lib/node_modules
      linkNodeModules = nodeModules: packages:
        if nodeModules == null
        then ""
        else ''
          nm_store=${nodeModules}
          echo "Linking node_modules from $nm_store..."

          # Detect layout
          ${jackpkgsLib.nodejs.findNodeModulesRoot "nm_root" "$nm_store"}

          if [ -z "$nm_root" ]; then
            echo "ERROR: Unable to find node_modules in $nm_store" >&2
            echo "Expected one of: node_modules/, lib/node_modules/, or lib/node_modules/default/node_modules/" >&2
            echo "Enable Node.js module or provide custom nodeModules via jackpkgs.checks.typescript.tsc.nodeModules" >&2
            exit 1
          fi

          # Link root node_modules
          ln -sfn "$nm_root" node_modules

          # Link package-level node_modules
          ${lib.concatMapStringsSep "\n" (pkg: ''
              mkdir -p ${lib.escapeShellArg pkg}

              # Link nested node_modules for workspace packages
              if [ -d "$nm_root"/${lib.escapeShellArg pkg}/node_modules ]; then
                ln -sfn "$nm_root"/${lib.escapeShellArg pkg}/node_modules ${lib.escapeShellArg pkg}/node_modules
              fi
            '')
            packages}
        '';

      # ============================================================
      # Python Workspace Discovery
      # ============================================================

      pythonPerSystemCfg = config.jackpkgs.python or {};
      pythonWorkspaceArg = pythonWorkspace;

      # Discover Python workspace members from pyproject.toml
      discoverPythonMembers = workspaceRoot: pyprojectPath: let
        pyproject = builtins.fromTOML (builtins.readFile pyprojectPath);
        memberGlobs = pyproject.tool.uv.workspace.members or ["."];

        allMembers = lib.flatten (map (jackpkgsLib.expandWorkspaceGlob workspaceRoot) memberGlobs);

        hasProject = member:
          builtins.pathExists (workspaceRoot + "/${member}/pyproject.toml");
      in
        lib.filter hasProject allMembers;

      # Discover workspace members if Python module is enabled
      pythonWorkspaceMembers =
        if pythonCfg.enable or false && pythonCfg ? workspaceRoot && pythonCfg ? pyprojectPath && pythonCfg.workspaceRoot != null && pythonCfg.pyprojectPath != null
        then let
          validatedPath = jackpkgsLib.validateWorkspacePath pythonCfg.pyprojectPath;
          resolvedPyprojectPath = pythonCfg.workspaceRoot + "/${validatedPath}";
        in
          discoverPythonMembers pythonCfg.workspaceRoot resolvedPyprojectPath
        else [];

      # Build Python environment with dev tools for CI checks
      # Priority order:
      # 1. Use explicitly defined 'dev' environment if it's non-editable and has groups enabled
      # 2. Use any non-editable environment with includeGroups enabled
      # 3. Create a new environment with all dependency groups enabled
      pythonEnvWithDevTools = let
        # Get configured environments
        configuredEnvs = pythonCfg.environments or {};
        pythonEnvOutputs = config.jackpkgs.outputs.pythonEnvironments or {};

        isEditableEnv = envCfg: envCfg != null && (envCfg.editable or false);
        isNonEditableEnv = envCfg: envCfg != null && !isEditableEnv envCfg;

        # Check if an environment is suitable for CI (non-editable + groups enabled)
        # Note: envCfg.includeGroups can be null, true, or false (nullOr bool type).
        # Using `== true` correctly handles all cases: null→false, true→true, false→false.
        isCiEnvCandidate = envCfg:
          isNonEditableEnv envCfg
          && (envCfg.includeGroups or null) == true;

        # Check if a 'dev' environment is configured
        hasDevEnv = configuredEnvs ? dev;
        devEnvConfig = configuredEnvs.dev or null;

        # Find any environment with groups enabled
        envWithGroups =
          lib.findFirst
          (envName: isCiEnvCandidate (configuredEnvs.${envName} or null))
          null
          (lib.attrNames configuredEnvs);

        # Get the appropriate environment based on priority
        selectedEnv =
          if hasDevEnv && isCiEnvCandidate devEnvConfig
          then pythonEnvOutputs.dev or null
          else if envWithGroups != null
          then pythonEnvOutputs.${envWithGroups} or null
          else null;
      in
        if selectedEnv != null
        then selectedEnv
        else if pythonWorkspaceArg != null
        then
          # Create environment with all dependency groups for CI
          pythonWorkspaceArg.mkEnv {
            name = "python-ci-checks";
            spec = pythonWorkspaceArg.computeSpec {
              includeGroups = true;
            };
          }
        else null;

      # Extract Python version from environment for PYTHONPATH
      pythonVersion =
        if pythonPerSystemCfg ? pythonPackage && pythonPerSystemCfg.pythonPackage != null
        then
          # Prefer pythonVersion, fall back to deriving from version, then default
          pythonPerSystemCfg.pythonPackage.pythonVersion
            or (lib.versions.majorMinor pythonPerSystemCfg.pythonPackage.version or "3.12")
        else "3.12";

      # ============================================================
      # TypeScript Workspace Discovery
      # ============================================================

      projectRoot =
        if jackpkgsProjectRoot != null
        then jackpkgsProjectRoot
        else config.jackpkgs.projectRoot or inputs.self.outPath;

      tsPackages =
        if cfg.typescript.tsc.packages != null
        then map jackpkgsLib.validateWorkspacePath cfg.typescript.tsc.packages
        else discoverPnpmPackages projectRoot;

      vitestPackages =
        if cfg.vitest.packages != null
        then map jackpkgsLib.validateWorkspacePath cfg.vitest.packages
        else discoverPnpmPackages projectRoot;

      # NOTE: We cannot use builtins.pathExists on nodeModules paths at Nix evaluation
      # time because the derivation doesn't exist yet (it's built later). The path
      # existence checks must happen at runtime (in the shell script) when the
      # derivation has actually been built.

      # ============================================================
      # Python Checks
      # ============================================================

      pythonChecks =
        lib.optionalAttrs (cfg.enable && cfg.python.enable && pythonEnvWithDevTools != null && pythonWorkspaceMembers != [])
        (
          lib.optionalAttrs cfg.python.pytest.enable {
            # pytest check
            python-pytest = mkCheck {
              name = "python-pytest";
              buildInputs = [pythonEnvWithDevTools];
              setupCommands = ''
                export PYTHONPATH="${pythonEnvWithDevTools}/lib/python${pythonVersion}/site-packages"
                export COVERAGE_FILE=$TMPDIR/.coverage
              '';
              checkCommands = forEachWorkspaceMember {
                workspaceRoot = pythonCfg.workspaceRoot;
                members = pythonWorkspaceMembers;
                perMemberCommand = "pytest ${lib.escapeShellArgs cfg.python.pytest.extraArgs}";
              };
            };
          }
          // lib.optionalAttrs cfg.python.mypy.enable {
            # mypy check
            python-mypy = mkCheck {
              name = "python-mypy";
              buildInputs = [pythonEnvWithDevTools];
              setupCommands = ''
                export PYTHONPATH="${pythonEnvWithDevTools}/lib/python${pythonVersion}/site-packages"
                export MYPY_CACHE_DIR=$TMPDIR/.mypy_cache
              '';
              checkCommands = forEachWorkspaceMember {
                workspaceRoot = pythonCfg.workspaceRoot;
                members = pythonWorkspaceMembers;
                perMemberCommand = "mypy ${lib.escapeShellArgs cfg.python.mypy.extraArgs} .";
              };
            };
          }
          // lib.optionalAttrs cfg.python.ruff.enable {
            # ruff check
            python-ruff = mkCheck {
              name = "python-ruff";
              buildInputs = [pythonEnvWithDevTools];
              setupCommands = ''
                export RUFF_CACHE_DIR=$TMPDIR/.ruff_cache
              '';
              checkCommands = forEachWorkspaceMember {
                workspaceRoot = pythonCfg.workspaceRoot;
                members = pythonWorkspaceMembers;
                perMemberCommand = "ruff check ${lib.escapeShellArgs cfg.python.ruff.extraArgs} .";
              };
            };
          }
        );

      # ============================================================
      # TypeScript Checks
      # ============================================================

      typescriptChecks =
        lib.optionalAttrs (cfg.enable && cfg.typescript.enable && tsPackages != [])
        (lib.optionalAttrs cfg.typescript.tsc.enable {
          # tsc check
          typescript-tsc = mkCheck {
            name = "typescript-tsc";
            buildInputs = [pkgs.nodejs pkgs.nodePackages.typescript];
            setupCommands = ''
              # Copy source to writeable directory
              cp -R ${lib.escapeShellArg projectRoot} src
              chmod -R +w src
              cd src
              ${linkNodeModules (
                  if cfg.typescript.tsc.nodeModules != null
                  then cfg.typescript.tsc.nodeModules
                  else config.jackpkgs.outputs.nodeModules or null
                )
                tsPackages}
            '';
            checkCommands =
              lib.concatMapStringsSep "\n" (pkg: ''
                                            echo "Type-checking ${lib.escapeShellArg pkg}..."

                                            # Validate node_modules exists
                                            if [ ! -d "node_modules" ] && [ ! -d ${lib.escapeShellArg pkg}/node_modules ]; then
                                              cat >&2 <<'EOF'
                ERROR: node_modules not found for package: ${lib.escapeShellArg pkg}

                TypeScript checks require node_modules to be present.

                Enable the Node.js module to build node_modules via buildNpmPackage:

                    jackpkgs.nodejs.enable = true;

                This provides a pure, reproducible node_modules derivation that works
                in Nix sandbox builds. See ADR-020 for configuration details.

                To disable TypeScript checks: jackpkgs.checks.typescript.enable = false;
                EOF
                                              exit 1
                                            fi

                                            cd ${lib.escapeShellArg pkg}
                                            tsc --noEmit ${lib.escapeShellArgs cfg.typescript.tsc.extraArgs}
                                            cd - >/dev/null
              '')
              tsPackages;
          };
        });

      # ============================================================
      # Vitest Checks
      # ============================================================

      vitestNodeModules =
        if cfg.vitest.nodeModules != null
        then cfg.vitest.nodeModules
        else config.jackpkgs.outputs.nodeModules or null;

      vitestChecks = lib.optionalAttrs (cfg.enable && cfg.vitest.enable && vitestPackages != []) {
        javascript-vitest = mkCheck {
          name = "javascript-vitest";
          buildInputs = [pkgs.nodejs];
          setupCommands = ''
            # Copy source to writeable directory
            cp -R ${lib.escapeShellArg projectRoot} src
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
              VITEST_BIN="vitest"
            else
              VITEST_BIN=""
            fi
            export VITEST_BIN
          '';
          checkCommands =
            lib.concatMapStringsSep "\n" (pkg: ''
              echo "Testing ${lib.escapeShellArg pkg}..."
              cd ${lib.escapeShellArg pkg}

              # Use vitest binary found in setupCommands
              if [ -n "$VITEST_BIN" ]; then
                $VITEST_BIN ${lib.escapeShellArgs cfg.vitest.extraArgs}
              else
                echo "WARNING: Vitest binary not found for ${lib.escapeShellArg pkg}, skipping."
                # Don't fail the build if vitest isn't set up for this specific package
                # (some packages in workspace might not have tests)
              fi
              cd - >/dev/null
            '')
            vitestPackages;
        };
      };
    in
      # Merge all checks into the checks attribute
      lib.mkMerge [
        {checks = pythonChecks;}
        {checks = typescriptChecks;}
        {checks = vitestChecks;}
      ];
  };
}
