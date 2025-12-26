{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.python;
in {
  imports = [
    jackpkgsInputs.flake-root.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.python = {
      enable = mkEnableOption "jackpkgs-python (opinionated Python envs via uv2nix)" // {default = false;};

      # Paths (as strings; resolve only when enabled)
      pyprojectPath = mkOption {
        type = types.str;
        default = "./pyproject.toml";
        description = "Relative path to pyproject.toml (evaluated only when enabled).";
      };

      uvLockPath = mkOption {
        type = types.str;
        default = "./uv.lock";
        description = "Relative path to uv.lock (evaluated only when enabled).";
      };

      workspaceRoot = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Workspace root as a Nix path (e.g., ./.). Required when jackpkgs.python.enable = true.";
      };

      # Build configuration
      sourcePreference = mkOption {
        type = types.enum ["wheel" "sdist"];
        default = "wheel";
        description = "Prefer wheels or source distributions when available.";
      };

      extraOverlays = mkOption {
        type = types.listOf types.unspecified;
        default = [];
        description = "Additional overlays to apply to the Python package set.";
      };

      # Darwin-specific
      darwin.sdkVersion = mkOption {
        type = types.str;
        default = "15.0";
        description = "macOS SDK version for Darwin builds.";
      };

      # Package fixes
      setuptools.packages = mkOption {
        type = types.listOf types.str;
        default = ["peewee" "multitasking" "sgmllib3k"];
        description = "Packages that need setuptools added to nativeBuildInputs.";
      };

      # Environment definitions
      environments = mkOption {
        type = types.attrsOf (types.submodule ({config, ...}: {
          options = {
            name = mkOption {
              type = types.str;
              description = "Name of the virtual environment and package output.";
            };

            editable = mkOption {
              type = types.bool;
              default = false;
              description = "Create editable install with workspace members.";
            };

            editableRoot = mkOption {
              type = types.str;
              default = "$REPO_ROOT";
              description = "Root path for editable installs (supports shell variables).";
            };

            members = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = "Specific workspace members to make editable (null = all).";
            };

            spec = mkOption {
              type = types.nullOr types.unspecified;
              default = null;
              description = "Custom dependency spec (overrides extras-based spec).";
            };

            passthru = mkOption {
              type = types.attrs;
              default = {};
              description = "Arbitrary metadata for tooling; unused by the module.";
            };
          };
        }));
        default = {};
        description = "Python virtual environments to create.";
        example = {
          default = {
            name = "python-env";
            spec = {}; # workspace.deps.default // { "my-package" = ["extras"]; }
          };
          dev = {
            name = "python-dev";
            editable = true;
            spec = {}; # workspace.deps.default // { "my-package" = ["dev"]; }
          };
        };
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      # Reusable editable Python shell hook fragment (read-only output option)
      options.jackpkgs.outputs.pythonEditableHook = mkOption {
        type = types.package;
        readOnly = true;
        description = "Editable Python shell hook fragment to include in `inputsFrom`.";
      };

      options.jackpkgs.outputs.pythonEnvironments = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        description = "Built Python environments keyed by jackpkgs.python.environments entries.";
      };

      options.jackpkgs.outputs.pythonDefaultEnv = mkOption {
        type = types.nullOr types.package;
        readOnly = true;
        description = "Default Python environment derivation when `jackpkgs.python.environments.default` exists.";
      };

      options.jackpkgs.python = {
        pythonPackage = mkOption {
          type = types.package;
          default = pkgs.python312;
          defaultText = "pkgs.python312";
          description = "Python package to use as base interpreter.";
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      inputs,
      ...
    }: let
      sysCfg = config.jackpkgs.python;
      # Resolve paths relative to the consumer project root
      rawProjectRoot = config._module.args.jackpkgsProjectRoot or (config.jackpkgs.projectRoot or inputs.self.outPath);
      projectRootString = builtins.toString rawProjectRoot;
      projectRoot =
        if builtins.isPath rawProjectRoot
        then rawProjectRoot
        else if lib.hasPrefix "/" projectRootString
        then builtins.toPath projectRootString
        else
          throw
          "jackpkgs.python: projectRoot must be a Nix path or absolute path string; got ${projectRootString}";
      appendToProjectRoot = relPath:
      # Accept either a path or a relative string; join strings against projectRoot
      let
        baseString = builtins.toString projectRoot;
      in
        if builtins.isPath relPath
        then relPath
        else
          (
            # Build an absolute path in string space and convert to a Nix path.
            # Avoid lib.path.normalise (not available in some lib versions) and
            # trim duplicate separators conservatively.
            let
              sub =
                if lib.hasPrefix "/" relPath
                then builtins.substring 1 (builtins.stringLength relPath - 1) relPath
                else relPath;
              sep =
                if lib.hasSuffix "/" baseString
                then ""
                else "/";
            in
              builtins.toPath (baseString + sep + sub)
          );
      pyprojectPath = appendToProjectRoot cfg.pyprojectPath;
      uvLockPath = appendToProjectRoot cfg.uvLockPath;
      workspaceRoot =
        if cfg.workspaceRoot == "."
        then projectRoot
        else appendToProjectRoot cfg.workspaceRoot;

      # Ensure uv2nix receives a Nix path for workspaceRoot (fail fast with a clear error)
      wsRootPathAssert =
        if (cfg.workspaceRoot == null) || (!builtins.isPath workspaceRoot)
        then throw "jackpkgs.python: workspaceRoot (path) is required when jackpkgs.python.enable = true; set, e.g., ./."
        else null;

      # Force evaluation so a non-path cannot leak into uv2nix
      __forceWsRootPathAssert = wsRootPathAssert;

      # Validate pyproject.toml exists and has either [project] or [tool.uv.workspace]
      pyproject =
        if builtins.pathExists pyprojectPath
        then builtins.fromTOML (builtins.readFile pyprojectPath)
        else {};

      # Light validation: ensure either [project] or [tool.uv.workspace] exists
      _ =
        if !(pyproject ? project || (pyproject ? tool && pyproject.tool ? uv && pyproject.tool.uv ? workspace))
        then throw "jackpkgs.python: pyproject.toml must contain [project] or [tool.uv.workspace]"
        else null;

      # uv2nix workspace and python set
      workspace =
        if builtins.pathExists uvLockPath
        then jackpkgsInputs.uv2nix.lib.workspace.loadWorkspace {inherit workspaceRoot;}
        else throw ("jackpkgs.python: uv.lock not found at " + builtins.toString uvLockPath + " — run 'uv lock' in the project to generate it.");

      # Extension: Darwin SDK version handling for macOS compatibility
      # Not documented in uv2nix, but necessary for real-world macOS builds
      # Nixpkgs lacks knowledge of target macOS version, so we explicitly set SDK version
      stdenvForPython =
        if pkgs.stdenv.isDarwin
        then
          pkgs.stdenv.override {
            targetPlatform =
              pkgs.stdenv.targetPlatform
              // {
                darwinSdkVersion = cfg.darwin.sdkVersion;
              };
          }
        else pkgs.stdenv;

      pythonBase = pkgs.callPackage jackpkgsInputs.pyproject-nix.build.packages {
        python = sysCfg.pythonPackage;
        stdenv = stdenvForPython;
      };

      baseOverlay = workspace.mkPyprojectOverlay {
        sourcePreference = cfg.sourcePreference;
      };

      # Extension: Setuptools override overlay for packages with broken/missing build deps
      # Not documented in uv2nix, but necessary workaround for upstream packaging issues
      # Some packages don't properly declare setuptools in their build-system dependencies
      ensureSetuptools = final: prev: let
        add = name:
          if builtins.hasAttr name prev
          then
            lib.nameValuePair name (prev.${name}.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or []) ++ [final.setuptools];
            }))
          else null;
        pairs = builtins.filter (x: x != null) (map add cfg.setuptools.packages);
      in
        builtins.listToAttrs pairs;

      # Build system overlay should match sourcePreference (wheel OR sdist, not both)
      # Per uv2nix docs: "The build system overlay has the same sdist/wheel distinction as mkPyprojectOverlay"
      overlayList =
        [baseOverlay]
        ++ (
          if cfg.sourcePreference == "wheel"
          then [jackpkgsInputs.pyproject-build-systems.overlays.wheel]
          else [jackpkgsInputs.pyproject-build-systems.overlays.sdist]
        )
        ++ [ensureSetuptools]
        ++ cfg.extraOverlays;

      pythonSet = pythonBase.overrideScope (lib.composeManyExtensions overlayList);

      defaultSpec = workspace.deps.default;

      # Extension: Virtual environment post-processing for better UX
      # Not documented in uv2nix, but provides:
      # - mainProgram metadata for better `nix run` experience
      # - PowerShell script removal (appears in output, likely upstream bug)
      # - Activation script permissions fix (should be executable by default)
      addMainProgram = drv:
        drv.overrideAttrs (old: {
          meta = (old.meta or {}) // {mainProgram = "python";};
          postFixup =
            (lib.optionalString (old ? postFixup) old.postFixup)
            + ''
              if [ -f "$out/bin/Activate.ps1" ]; then
                rm -f "$out/bin/Activate.ps1"
              fi
              if [ -d "$out/bin" ]; then
                chmod +x "$out/bin"/activate* 2>/dev/null || true
              fi
            '';
        });

      mkEnvForSpec = {
        name,
        spec,
      }:
        addMainProgram (pythonSet.mkVirtualEnv name spec);

      mkEnv = {
        name,
        spec ? null,
      }: let
        finalSpec =
          if spec == null
          then defaultSpec
          else spec;
      in
        mkEnvForSpec {
          inherit name;
          spec = finalSpec;
        };

      mkEditableEnv = {
        name,
        spec ? null,
        members ? null,
        root ? null,
      }: let
        finalSpec =
          if spec == null
          then defaultSpec
          else spec;
        # Use flake-root by default, or accept an explicit runtime path string.
        # The overlay expects a runtime-resolvable string, not a Nix store path.
        defaultRoot = "$(${lib.getExe config.flake-root.package})";
        finalRoot =
          if root != null
          then root
          else defaultRoot;
        overlayArgs = {root = finalRoot;} // lib.optionalAttrs (members != null) {inherit members;};
        editableSet = pythonSet.overrideScope (workspace.mkEditablePyprojectOverlay overlayArgs);
      in
        addMainProgram (editableSet.mkVirtualEnv name finalSpec);

      pythonWorkspace = {
        inherit workspace pythonSet defaultSpec;
        inherit mkEnv mkEditableEnv mkEnvForSpec;
      };

      pythonEnvs =
        lib.mapAttrs (
          envKey: envCfg:
            if envCfg.editable
            then
              pythonWorkspace.mkEditableEnv {
                name = envCfg.name;
                spec = envCfg.spec;
                members = envCfg.members;
                root = envCfg.editableRoot;
              }
            else
              pythonWorkspace.mkEnv {
                name = envCfg.name;
                spec = envCfg.spec;
              }
        )
        cfg.environments;

      envNames = map (e: e.name) (lib.attrValues cfg.environments);
      uniqueEnvNames = lib.unique envNames;
      _envNamesCheck =
        if envNames != uniqueEnvNames
        then throw ("jackpkgs.python: duplicate environment package names detected: " + builtins.toString envNames)
        else null;

      # Validate at most one editable environment
      editableKeys = lib.attrNames (lib.filterAttrs (_: envCfg: envCfg.editable) cfg.environments);
      _editableCountCheck =
        if (lib.length editableKeys) > 1
        then throw ("jackpkgs.python: at most one environment may have editable = true; found: " + lib.concatStringsSep ", " editableKeys)
        else null;
    in {
      # Reusable editable Python shell hook fragment
      jackpkgs.outputs.pythonEditableHook = pkgs.mkShell (
        let
          editableKey =
            if editableKeys == []
            then null
            else lib.head editableKeys;
          editableEnv =
            if editableKey == null
            then null
            else pythonEnvs.${editableKey};
        in {
          packages = lib.optional (editableEnv != null) editableEnv;
          shellHook = ''
            repo_root="$(${lib.getExe config.flake-root.package})"
            export REPO_ROOT="$repo_root"
            # Unset PYTHONPATH to prevent Python from incorrectly importing packages from the Nix build environment instead of the virtual environment (uv2nix best practice)
            unset PYTHONPATH

            ${lib.optionalString (editableEnv != null) ''
              export UV_NO_SYNC="1"
              export UV_PYTHON="${lib.getExe editableEnv}"
              export UV_PYTHON_DOWNLOADS="never"
              export PATH="${editableEnv}/bin:$PATH"
            ''}
          '';
        }
      );

      # Automatically include editable hook in devshell
      jackpkgs.shell.inputsFrom = [
        config.jackpkgs.outputs.pythonEditableHook
      ];

      jackpkgs.outputs.pythonEnvironments = pythonEnvs;
      jackpkgs.outputs.pythonDefaultEnv =
        if cfg.environments ? default
        then pythonEnvs.default
        else null;

      # Ensure uv is available in the devshell when python module is enabled
      jackpkgs.shell.packages = lib.mkIf cfg.enable [pkgs.uv];

      # Always expose pythonWorkspace as module arg
      _module.args.pythonWorkspace = pythonWorkspace;

      # Publish only non-editable envs as packages.<name>
      packages = lib.listToAttrs (
        builtins.filter (x: x != null) (
          lib.mapAttrsToList (
            envKey: envCfg:
              if envCfg.editable
              then null
              else lib.nameValuePair envCfg.name (pythonEnvs.${envKey})
          )
          cfg.environments
        )
      );
    };
  };
}
