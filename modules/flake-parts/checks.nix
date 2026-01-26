{jackpkgsInputs}: {
  inputs,
  config,
  lib,
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
            || (config.jackpkgs.pulumi.enable or false);
          description = ''
            Enable CI checks for jackpkgs projects. Automatically enabled when
            Python or Pulumi modules are enabled.
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
            default = [];
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
            default = config.jackpkgs.outputs.nodeModules or null;
            description = ''
              Derivation containing the `node_modules` structure to link before running checks.
              Typically provided automatically by `jackpkgs.nodejs`.
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
              using a simple parser. Auto-discovery is best-effort and supports
              only basic YAML list syntax (single-quoted, double-quoted, or unquoted
              strings, comments, simple globs).

              Auto-discovery does NOT support: YAML anchors/aliases, multi-line
              strings, inline arrays, or paths with unescaped quotes inside values.
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

      # Jest check
      jest = {
        enable =
          mkEnableOption "Jest CI checks"
          // {
            default = config.jackpkgs.nodejs.enable or false;
            description = ''
              Enable Jest test runner. Automatically enabled when the Node.js module is enabled.
            '';
          };

        nodeModules = mkOption {
          type = types.nullOr types.package;
          default = config.jackpkgs.outputs.nodeModules or null;
          description = ''
            Derivation containing the `node_modules` structure to link before running checks.
            Typically provided automatically by `jackpkgs.nodejs`.
          '';
        };

        packages = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = ''
            List of packages to test with Jest.
            If null, uses same discovery as tsc (pnpm-workspace.yaml).
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra arguments to pass to Jest";
          example = ["--coverage" "--verbose"];
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

      # Validate workspace paths to prevent path traversal attacks
      # Rejects paths containing ".." or starting with "/"
      validateWorkspacePath = path:
        if lib.hasInfix ".." path
        then throw "Invalid workspace path '${path}': contains '..' (path traversal not allowed for security)"
        else if lib.hasPrefix "/" path
        then throw "Invalid workspace path '${path}': absolute paths not allowed (must be relative to workspace root)"
        else path;

      # Link node_modules into the sandbox
      # Strategy: Link root node_modules, then iterate through packages and link their node_modules if present in the store
      linkNodeModules = nodeModules: packages:
        if nodeModules == null
        then ""
        else ''
          echo "Linking node_modules from ${lib.escapeShellArg nodeModules}..."

          # Link root node_modules
          if [ -d ${lib.escapeShellArg nodeModules}/lib/node_modules ]; then
             # dream2nix often puts modules in lib/node_modules
             ln -sfn ${lib.escapeShellArg nodeModules}/lib/node_modules node_modules
          elif [ -d ${lib.escapeShellArg nodeModules}/node_modules ]; then
             ln -sfn ${lib.escapeShellArg nodeModules}/node_modules node_modules
          else
             echo "WARNING: Could not find node_modules in provided derivation"
          fi

          # Link package-level node_modules (if they exist in the derivation structure)
          ${lib.concatMapStringsSep "\n" (pkg: ''
              mkdir -p ${lib.escapeShellArg pkg}
              # Check for nested node_modules in the store output (common in monorepos)
              if [ -d ${lib.escapeShellArg nodeModules}/lib/node_modules/${lib.escapeShellArg pkg}/node_modules ]; then
                ln -sfn ${lib.escapeShellArg nodeModules}/lib/node_modules/${lib.escapeShellArg pkg}/node_modules ${lib.escapeShellArg pkg}/node_modules
              elif [ -d ${lib.escapeShellArg nodeModules}/${lib.escapeShellArg pkg}/node_modules ]; then
                ln -sfn ${lib.escapeShellArg nodeModules}/${lib.escapeShellArg pkg}/node_modules ${lib.escapeShellArg pkg}/node_modules
              fi
            '')
            packages}
        '';

      # Expand workspace globs like "tools/*" -> ["tools/hello", "tools/ocr"]
      # Used by both Python and TypeScript workspace discovery
      expandWorkspaceGlob = workspaceRoot: glob: let
        validatedGlob = validateWorkspacePath glob;
      in
        if lib.hasSuffix "/*" validatedGlob
        then let
          dir = lib.removeSuffix "/*" validatedGlob;
          fullPath = workspaceRoot + "/${dir}";
          entries =
            if builtins.pathExists fullPath
            then builtins.readDir fullPath
            else {};
          subdirs = lib.filterAttrs (name: type: type == "directory" && name != "." && name != "..") entries;
        in
          map (name: "${dir}/${name}") (lib.attrNames subdirs)
        else [validatedGlob];

      # ============================================================
      # Python Workspace Discovery
      # ============================================================

      pythonPerSystemCfg = config.jackpkgs.python or {};
      pythonWorkspaceArg = pythonWorkspace;

      # Discover Python workspace members from pyproject.toml
      discoverPythonMembers = workspaceRoot: pyprojectPath: let
        pyproject = builtins.fromTOML (builtins.readFile pyprojectPath);
        memberGlobs = pyproject.tool.uv.workspace.members or ["."];

        allMembers = lib.flatten (map (expandWorkspaceGlob workspaceRoot) memberGlobs);

        # Filter for directories with pyproject.toml
        hasProject = member:
          builtins.pathExists (workspaceRoot + "/${member}/pyproject.toml");
      in
        lib.filter hasProject allMembers;

      # Discover workspace members if Python module is enabled
      pythonWorkspaceMembers =
        if pythonCfg.enable or false && pythonCfg ? workspaceRoot && pythonCfg ? pyprojectPath && pythonCfg.workspaceRoot != null && pythonCfg.pyprojectPath != null
        then let
          # Validate and resolve pyprojectPath (string like "./pyproject.toml")
          # Security: validateWorkspacePath rejects ".." and absolute paths to prevent
          # reading arbitrary files outside the workspace (e.g., "../../../../etc/passwd")
          validatedPath = validateWorkspacePath pythonCfg.pyprojectPath;
          resolvedPyprojectPath = pythonCfg.workspaceRoot + "/${validatedPath}";
        in
          discoverPythonMembers pythonCfg.workspaceRoot resolvedPyprojectPath
        else [];

      # Build Python environment with dev tools for CI checks
      pythonEnvWithDevTools =
        if pythonWorkspaceArg != null
        then
          pythonWorkspaceArg.mkEnv {
            name = "python-ci-checks";
            spec = pythonWorkspaceArg.defaultSpec;
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

      # Discover pnpm workspace packages from pnpm-workspace.yaml
      # YAML Parser Limitations: This is a simple line-by-line parser that supports
      # basic YAML list syntax under 'packages:' key. It handles single-quoted, double-quoted,
      # and unquoted strings, comments, and simple indentation. It does NOT support: YAML
      # anchors/aliases, multi-line strings, inline arrays, complex nested structures, or
      # paths with unescaped quotes/apostrophes inside values (e.g., paths like foo"bar or
      # unquoted foo's-bar will fail; properly quoted "foo's-bar" or 'foo"bar' work fine).
      # For complex pnpm-workspace.yaml files, use explicit configuration via
      # jackpkgs.checks.typescript.tsc.packages option.
      discoverPnpmPackages = workspaceRoot: let
        yamlPath = workspaceRoot + "/pnpm-workspace.yaml";
        yamlExists = builtins.pathExists yamlPath;
        yamlLines =
          if yamlExists
          then lib.splitString "\n" (builtins.readFile yamlPath)
          else [];
        trimLine = line: let
          match = builtins.match "^[[:space:]]*(.*[^[:space:]])?[[:space:]]*$" line;
          head =
            if match == null
            then null
            else lib.head match;
        in
          if head == null
          then ""
          else head;
        parsePackageLine = line: let
          # Match package lines with double quotes, single quotes, or unquoted
          # Tries three patterns in order: double-quoted, single-quoted, unquoted
          doubleQuoted = builtins.match "^[[:space:]]*-[[:space:]]*\"([^\"]+)\".*$" line;
          singleQuoted = builtins.match "^[[:space:]]*-[[:space:]]*'([^']+)'.*$" line;
          unquoted = builtins.match "^[[:space:]]*-[[:space:]]*([^#\"']+).*$" line;
          head =
            if doubleQuoted != null
            then lib.head doubleQuoted
            else if singleQuoted != null
            then lib.head singleQuoted
            else if unquoted != null
            then lib.head unquoted
            else null;
        in
          if head == null
          then null
          else trimLine head; # Trim trailing whitespace from unquoted values
        parsed =
          lib.foldl' (
            acc: line: let
              trimmed = trimLine line;
              isPackagesKey = builtins.match "^packages:([[:space:]]*(#.*)?)?$" trimmed != null;
              isTopLevelKey = builtins.match "^[^[:space:]]+:[[:space:]]*.*$" trimmed != null;
              pkg = parsePackageLine line;
            in
              if isPackagesKey
              then acc // {inPackages = true;}
              else if acc.inPackages && isTopLevelKey
              then acc // {inPackages = false;}
              else if acc.inPackages && pkg != null
              then acc // {packages = acc.packages ++ [pkg];}
              else acc
          ) {
            inPackages = false;
            packages = [];
          }
          yamlLines;
        packageGlobs = parsed.packages or [];

        allPackages = lib.flatten (map (expandWorkspaceGlob workspaceRoot) packageGlobs);

        # Filter for directories with package.json
        hasPackageJson = pkg:
          builtins.pathExists (workspaceRoot + "/${pkg}/package.json");
      in
        if yamlExists
        then lib.filter hasPackageJson allPackages
        else [];

      # Determine TypeScript packages to check
      tsPackages =
        if cfg.typescript.tsc.packages != null
        then cfg.typescript.tsc.packages
        else discoverPnpmPackages projectRoot;

      # Determine Jest packages
      jestPackages =
        if cfg.jest.packages != null
        then cfg.jest.packages
        else discoverPnpmPackages projectRoot;

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
              ${linkNodeModules cfg.typescript.tsc.nodeModules tsPackages}
            '';
            checkCommands =
              lib.concatMapStringsSep "\n" (pkg: ''
                            echo "Type-checking ${lib.escapeShellArg pkg}..."

                            # Validate node_modules exists
                            if [ ! -d "node_modules" ] && [ ! -d ${lib.escapeShellArg pkg}/node_modules ]; then
                              cat >&2 << EOF
                ERROR: node_modules not found for package: ${pkg}

                TypeScript checks require node_modules to be present.

                Solution 1 (Pure Nix - Recommended):
                  Enable the Node.js module to automatically build node_modules:
                  jackpkgs.nodejs.enable = true;

                Solution 2 (Impure/Local):
                  Run 'pnpm install' locally before running checks.

                Or disable TypeScript checks:
                  jackpkgs.checks.typescript.enable = false;
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
      # Jest Checks
      # ============================================================

      jestChecks = lib.optionalAttrs (cfg.enable && cfg.jest.enable && jestPackages != []) {
        javascript-jest = mkCheck {
          name = "javascript-jest";
          buildInputs = [pkgs.nodejs];
          setupCommands = ''
            # Copy source to writeable directory
            cp -R ${lib.escapeShellArg projectRoot} src
            chmod -R +w src
            cd src
            ${linkNodeModules cfg.jest.nodeModules jestPackages}
          '';
          checkCommands =
            lib.concatMapStringsSep "\n" (pkg: ''
              echo "Testing ${lib.escapeShellArg pkg}..."
              cd ${lib.escapeShellArg pkg}

              # Check if jest exists in linked node_modules (pure) or local (impure)
              JEST_BIN=""
              if [ -f "node_modules/.bin/jest" ]; then
                JEST_BIN="./node_modules/.bin/jest"
              elif [ -f "../../node_modules/.bin/jest" ]; then
                JEST_BIN="../../node_modules/.bin/jest"
              elif [ -f "node_modules/jest/bin/jest.js" ]; then
                 JEST_BIN="node node_modules/jest/bin/jest.js"
              fi

              if [ -n "$JEST_BIN" ]; then
                $JEST_BIN ${lib.escapeShellArgs cfg.jest.extraArgs}
              else
                 echo "WARNING: Jest binary not found for ${pkg}, skipping."
                 # Don't fail the build if jest isn't set up for this specific package
                 # (some packages in workspace might not have tests)
              fi
              cd - >/dev/null
            '')
            jestPackages;
        };
      };
    in
      # Merge all checks into the checks attribute
      lib.mkMerge [
        {checks = pythonChecks;}
        {checks = typescriptChecks;}
        {checks = jestChecks;}
      ];
  };
}
