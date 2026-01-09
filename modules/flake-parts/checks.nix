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

          packages = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              List of packages to type-check. If null, packages will be
              auto-discovered from pnpm-workspace.yaml.
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
          (cd "${workspaceRoot}/${member}" && ${perMemberCommand})
        '')
        members;

      # ============================================================
      # Python Workspace Discovery
      # ============================================================

      pythonPerSystemCfg = config.jackpkgs.python or {};
      pythonWorkspaceArg = pythonWorkspace;

      # Discover Python workspace members from pyproject.toml
      discoverPythonMembers = workspaceRoot: pyprojectPath: let
        pyproject = builtins.fromTOML (builtins.readFile pyprojectPath);
        memberGlobs = pyproject.tool.uv.workspace.members or ["."];

        # Expand globs like "tools/*" -> ["tools/hello", "tools/ocr"]
        expandGlob = glob:
          if lib.hasSuffix "/*" glob
          then let
            dir = lib.removeSuffix "/*" glob;
            fullPath = workspaceRoot + "/${dir}";
            entries =
              if builtins.pathExists fullPath
              then builtins.readDir fullPath
              else {};
            subdirs = lib.filterAttrs (_: type: type == "directory") entries;
          in
            map (name: "${dir}/${name}") (lib.attrNames subdirs)
          else [glob];

        allMembers = lib.flatten (map expandGlob memberGlobs);

        # Filter for directories with pyproject.toml
        hasProject = member:
          builtins.pathExists (workspaceRoot + "/${member}/pyproject.toml");
      in
        lib.filter hasProject allMembers;

      # Discover workspace members if Python module is enabled
      pythonWorkspaceMembers =
        if pythonCfg.enable or false && pythonCfg ? workspaceRoot && pythonCfg ? pyprojectPath && pythonCfg.workspaceRoot != null && pythonCfg.pyprojectPath != null
        then let
          # Resolve pyprojectPath relative to workspaceRoot (pyprojectPath is a string like "./pyproject.toml")
          resolvedPyprojectPath = pythonCfg.workspaceRoot + "/${pythonCfg.pyprojectPath}";
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
        then pythonPerSystemCfg.pythonPackage.pythonVersion or "3.12"
        else "3.12";

      # ============================================================
      # TypeScript Workspace Discovery
      # ============================================================

      projectRoot =
        if jackpkgsProjectRoot != null
        then jackpkgsProjectRoot
        else config.jackpkgs.projectRoot or inputs.self.outPath;

      # Discover pnpm workspace packages from pnpm-workspace.yaml
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
          match = builtins.match "^[[:space:]]*-[[:space:]]*\"?([^\"#]+)\"?.*$" line;
          head =
            if match == null
            then null
            else lib.head match;
        in
          if head == null
          then null
          else head;
        parsed =
          lib.foldl' (
            acc: line: let
              trimmed = trimLine line;
              isPackagesKey = builtins.match "^packages:[[:space:]]*(#.*)?$" trimmed != null;
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

        # Expand globs like "tools/*" -> ["tools/hello", "tools/ocr"]
        expandGlob = glob:
          if lib.hasSuffix "/*" glob
          then let
            dir = lib.removeSuffix "/*" glob;
            fullPath = workspaceRoot + "/${dir}";
            entries =
              if builtins.pathExists fullPath
              then builtins.readDir fullPath
              else {};
            subdirs = lib.filterAttrs (_: type: type == "directory") entries;
          in
            map (name: "${dir}/${name}") (lib.attrNames subdirs)
          else [glob];

        allPackages = lib.flatten (map expandGlob packageGlobs);

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

      # ============================================================
      # Python Checks
      # ============================================================

      pythonChecks =
        lib.optionalAttrs (cfg.enable && cfg.python.enable && pythonEnvWithDevTools != null)
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
            checkCommands =
              lib.concatMapStringsSep "\n" (pkg: ''
                            echo "Type-checking ${pkg}..."

                            # Validate node_modules exists
                            if [ ! -d "${projectRoot}/${pkg}/node_modules" ]; then
                              cat >&2 << EOF
                ERROR: node_modules not found for package: ${pkg}

                TypeScript checks require node_modules to be present.
                Please run: pnpm install

                Or disable TypeScript checks:
                  jackpkgs.checks.typescript.enable = false;
                EOF
                              exit 1
                            fi

                            cd "${projectRoot}/${pkg}"
                            tsc --noEmit ${lib.escapeShellArgs cfg.typescript.tsc.extraArgs}
              '')
              tsPackages;
          };
        });
    in
      # Merge all checks into the checks attribute
      lib.mkMerge [
        {checks = pythonChecks;}
        {checks = typescriptChecks;}
      ];
  };
}
