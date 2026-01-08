{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types mkEnableOption;
  cfg = config.jackpkgs.checks;
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
          (cd ${workspaceRoot}/${member} && ${perMemberCommand})
        '')
        members;

      # ============================================================
      # Python Workspace Discovery
      # ============================================================

      pythonCfg = config.jackpkgs.python or {};
      pythonWorkspace = config._module.args.pythonWorkspace or null;

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
        if pythonCfg.enable or false && pythonCfg ? workspaceRoot && pythonCfg ? pyprojectPath
        then discoverPythonMembers pythonCfg.workspaceRoot pythonCfg.pyprojectPath
        else [];

      # Build Python environment with dev tools for CI checks
      pythonEnvWithDevTools =
        if pythonWorkspace != null
        then
          pythonWorkspace.mkEnv {
            name = "python-ci-checks";
            spec = pythonWorkspace.defaultSpec;
          }
        else null;

      # Extract Python version from environment for PYTHONPATH
      pythonVersion =
        if pythonCfg ? pythonPackage && pythonCfg.pythonPackage != null
        then pythonCfg.pythonPackage.pythonVersion or "3.12"
        else "3.12";

      # ============================================================
      # TypeScript Workspace Discovery
      # ============================================================

      pulumiCfg = config.jackpkgs.pulumi or {};
      projectRoot =
        config._module.args.jackpkgsProjectRoot
        or config.jackpkgs.projectRoot
        or inputs.self.outPath;

      # Discover pnpm workspace packages from pnpm-workspace.yaml
      discoverPnpmPackages = workspaceRoot: let
        yamlPath = workspaceRoot + "/pnpm-workspace.yaml";
        yamlExists = builtins.pathExists yamlPath;

        # Convert YAML to JSON using remarshal (IFD)
        jsonFile =
          pkgs.runCommand "pnpm-workspace.json" {
            buildInputs = [pkgs.remarshal];
          } ''
            remarshal -if yaml -of json < ${yamlPath} > $out
          '';

        workspaceData = builtins.fromJSON (builtins.readFile jsonFile);
        packageGlobs = workspaceData.packages or [];

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

      pythonChecks = lib.optionalAttrs (cfg.enable && cfg.python.enable && pythonEnvWithDevTools != null) {
        # pytest check
        python-pytest = mkIf cfg.python.pytest.enable (mkCheck {
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
        });

        # mypy check
        python-mypy = mkIf cfg.python.mypy.enable (mkCheck {
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
        });

        # ruff check
        python-ruff = mkIf cfg.python.ruff.enable (mkCheck {
          name = "python-ruff";
          buildInputs = [pythonEnvWithDevTools];
          checkCommands = forEachWorkspaceMember {
            workspaceRoot = pythonCfg.workspaceRoot;
            members = pythonWorkspaceMembers;
            perMemberCommand = "ruff check ${lib.escapeShellArgs cfg.python.ruff.extraArgs} .";
          };
        });
      };

      # ============================================================
      # TypeScript Checks
      # ============================================================

      typescriptChecks = lib.optionalAttrs (cfg.enable && cfg.typescript.enable && tsPackages != []) {
        # tsc check
        typescript-tsc = mkIf cfg.typescript.tsc.enable (mkCheck {
          name = "typescript-tsc";
          buildInputs = [pkgs.nodejs pkgs.nodePackages.typescript];
          checkCommands =
            lib.concatMapStringsSep "\n" (pkg: ''
                          echo "Type-checking ${pkg}..."

                          # Validate node_modules exists
                          if [ ! -d "${projectRoot}/${pkg}/node_modules" ]; then
                            cat >&2 << 'EOF'
              ERROR: node_modules not found for package: ${pkg}

              TypeScript checks require node_modules to be present.
              Please run: pnpm install

              Or disable TypeScript checks:
                jackpkgs.checks.typescript.enable = false;
              EOF
                            exit 1
                          fi

                          cd ${projectRoot}/${pkg}
                          tsc --noEmit ${lib.escapeShellArgs cfg.typescript.tsc.extraArgs}
            '')
            tsPackages;
        });
      };
    in
      # Merge all checks into the checks attribute
      lib.mkMerge [
        {checks = pythonChecks;}
        {checks = typescriptChecks;}
      ];
  };
}
