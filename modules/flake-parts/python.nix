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
        type = types.str;
        default = ".";
        description = "Relative path to the uv workspace root (evaluated only when enabled).";
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

            extras = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Optional dependency groups to include (e.g., 'jupyter', 'dev').";
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
          default = {name = "python-env";};
          jupyter = {
            name = "python-jupyter";
            extras = ["jupyter"];
          };
          dev = {
            name = "python-dev";
            editable = true;
          };
        };
      };

      # Output configuration
      outputs = {
        exposeWorkspace = mkOption {
          type = types.bool;
          default = true;
          description = "Expose pythonWorkspace as perSystem module arg.";
        };

        exposeEnvs = mkOption {
          type = types.bool;
          default = true;
          description = "Expose pythonEnvs as perSystem module arg.";
        };

        addToDevShell = mkOption {
          type = types.bool;
          default = false;
          description = "Add python devshell fragment to jackpkgs devShell via inputsFrom.";
        };
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.pythonDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Python devShell fragment to include in `inputsFrom`.";
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
      rawProjectRoot = config._module.args.jackpkgsProjectRoot or inputs.self.outPath;
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
      # Build an absolute path in string space and convert to a Nix path.
      # Avoid lib.path.normalise (not available in some lib versions) and
      # trim duplicate separators conservatively.
      let
        baseString = builtins.toString projectRoot;
        # relPath is a user-provided string option; ensure no leading '/'
        sub =
          if lib.hasPrefix "/" relPath
          then builtins.substring 1 (builtins.stringLength relPath - 1) relPath
          else relPath;
        sep =
          if lib.hasSuffix "/" baseString
          then ""
          else "/";
      in
        builtins.toPath (baseString + sep + sub);
      pyprojectPath = appendToProjectRoot cfg.pyprojectPath;
      uvLockPath = appendToProjectRoot cfg.uvLockPath;
      # Use the canonical project root as workspaceRoot (path-typed) to satisfy uv2nix.
      workspaceRoot = projectRoot;

      # Parse pyproject for project name (guarded to avoid eager failures)
      pyproject =
        if builtins.pathExists pyprojectPath
        then builtins.fromTOML (builtins.readFile pyprojectPath)
        else {};
      projectName =
        if pyproject ? project && pyproject.project ? name
        then pyproject.project.name
        else throw "jackpkgs.python: pyproject.toml is missing [project].name";

      # uv2nix workspace and python set
      workspace =
        if builtins.pathExists uvLockPath
        then jackpkgsInputs.uv2nix.lib.workspace.loadWorkspace {inherit workspaceRoot;}
        else throw ("jackpkgs.python: uv.lock not found at " + builtins.toString uvLockPath + " — run 'uv lock' in the project to generate it.");

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

      overlayList =
        [baseOverlay]
        ++ [
          jackpkgsInputs.pyproject-build-systems.overlays.wheel
          jackpkgsInputs.pyproject-build-systems.overlays.sdist
        ]
        ++ [ensureSetuptools]
        ++ cfg.extraOverlays;

      pythonSet = pythonBase.overrideScope (lib.composeManyExtensions overlayList);

      defaultSpec = workspace.deps.default;
      targetName =
        if lib.hasAttr projectName defaultSpec
        then projectName
        else lib.head (builtins.attrNames defaultSpec);

      ensureList = value:
        if builtins.isList value
        then value
        else if lib.isString value
        then [value]
        else value;

      specWithExtras = extras: let
        extrasList = lib.unique (ensureList extras);
      in
        if extrasList == []
        then defaultSpec
        else
          defaultSpec
          // {
            ${targetName} = lib.unique ((defaultSpec.${targetName} or []) ++ extrasList);
          };

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
        extras ? [],
        spec ? null,
      }: let
        finalSpec =
          if spec != null
          then spec
          else specWithExtras extras;
      in
        mkEnvForSpec {
          inherit name;
          spec = finalSpec;
        };

      mkEditableEnv = {
        name,
        extras ? [],
        spec ? null,
        members ? null,
        root ? "$REPO_ROOT",
      }: let
        # Keep editable root as a plain string (resolved at shell runtime).
        overlayArgs = {root = root;} // lib.optionalAttrs (members != null) {inherit members;};
        editableSet = pythonSet.overrideScope (workspace.mkEditablePyprojectOverlay overlayArgs);
        finalSpec =
          if spec != null
          then spec
          else specWithExtras extras;
      in
        addMainProgram (editableSet.mkVirtualEnv name finalSpec);

      pythonWorkspace = {
        inherit workspace pythonSet projectName defaultSpec specWithExtras;
        mkEnv = mkEnv;
        mkEditableEnv = mkEditableEnv;
        mkEnvForSpec = mkEnvForSpec;
      };

      pythonEnvs =
        lib.mapAttrs (
          envKey: envCfg:
            if envCfg.editable
            then
              pythonWorkspace.mkEditableEnv {
                name = envCfg.name;
                extras = envCfg.extras;
                spec = envCfg.spec;
                members = envCfg.members;
                root = envCfg.editableRoot;
              }
            else
              pythonWorkspace.mkEnv {
                name = envCfg.name;
                extras = envCfg.extras;
                spec = envCfg.spec;
              }
        )
        cfg.environments;

      envNames = map (e: e.name) (lib.attrValues cfg.environments);
      uniqueEnvNames = lib.unique envNames;
      _ =
        if envNames != uniqueEnvNames
        then throw ("jackpkgs.python: duplicate environment package names detected: " + builtins.toString envNames)
        else null;
    in {
      # Minimal devshell fragment now; still include base Python.
      jackpkgs.outputs.pythonDevShell = pkgs.mkShell {
        packages = [sysCfg.pythonPackage];
      };

      # Optionally contribute this fragment to the composed devshell
      jackpkgs.shell.inputsFrom = lib.optionals cfg.outputs.addToDevShell [
        config.jackpkgs.outputs.pythonDevShell
      ];

      # Export module args for power users
      _module.args = lib.mkMerge [
        (lib.optionalAttrs cfg.outputs.exposeWorkspace {pythonWorkspace = pythonWorkspace;})
        (lib.optionalAttrs cfg.outputs.exposeEnvs {pythonEnvs = pythonEnvs;})
      ];

      # Publish only non-editable envs as packages.<name>
      packages = lib.listToAttrs (
        builtins.filter (x: x != null) (
          lib.mapAttrsToList
          (
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
