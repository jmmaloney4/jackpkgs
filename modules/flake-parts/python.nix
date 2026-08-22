{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.python;
  namespaceCheck = import ../../lib/python-namespace-check.nix {inherit lib;};
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

      deterministicBytecode = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Recompile installed Python bytecode deterministically after wheel
          installation (PYTHONHASHSEED=0 + PEP 552 unchecked-hash pycs).

          uv's default bytecode compilation is timestamp-invalidated and
          inherits the sandbox's random PYTHONHASHSEED, so .pyc files with
          frozenset constants are not bit-reproducible across builders. The
          divergent realizations poison binary caches and break nix2container
          image pushes, whose recorded layer digests must match the pushing
          machine's store bytes (jackpkgs#355).

          Disabling this restores upstream pyproject-nix behavior.
        '';
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
        description = "Packages that need setuptools added to nativeBuildInputs. Retained as a compatibility shim around jackpkgs.python.buildFixes.";
      };

      buildFixes = mkOption {
        type = types.attrsOf (types.submodule ({...}: {
          options = {
            pythonNativeBuildInputs = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''
                Python packages from the uv2nix package set to append to nativeBuildInputs
                for this locked dependency. Use package attribute names such as
                "meson-python", "meson", or "ninja".
              '';
            };

            nativeBuildInputs = mkOption {
              type = types.listOf types.unspecified;
              default = [];
              description = ''
                Additional native build inputs from nixpkgs to append to nativeBuildInputs
                for this locked dependency.
              '';
            };
          };
        }));
        default = {};
        description = ''
          Declarative per-package source-build fixes for locked Python dependencies.
          Use this when a dependency falls back to sdist and needs extra Python build
          backends or native tools beyond what upstream metadata declares.
        '';
        example = lib.literalExpression ''
          {
            beancount = {
              pythonNativeBuildInputs = [ "meson-python" "meson" "ninja" ];
              nativeBuildInputs = [ pkgs.bison pkgs.flex ];
            };
          }
        '';
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
              description = ''
                Custom dependency spec (overrides all other spec-related options).
                When null, the spec is computed based on includeOptionalDependencies
                and includeGroups options.

                Format: attrset where keys are package names and values are lists of extras.
                Example: { "my-package" = ["dev" "test"]; }
              '';
            };

            includeGroups = mkOption {
              type = types.nullOr (types.either types.bool (types.listOf types.str));
              default = null;
              description = ''
                Which PEP 735 dependency groups ([dependency-groups] sections, or
                [tool.uv.dev-dependencies]) of workspace members to include when the
                spec is computed (i.e. when `spec` is null — an explicit `spec`
                overrides this option entirely).

                Accepts:
                - `true`  — include ALL groups defined by every member.
                - `false` — production only (each member's default-groups).
                - `[ "a" "b" ]` — include the named groups. For each member, the
                  effective groups are that member's default-groups UNIONED with the
                  requested names it actually defines (mirroring `uv sync --group`);
                  members that do not define a requested group simply skip it.
                  `[]` is therefore equivalent to `false`. Every requested name MUST
                  be defined by at least one workspace member, or evaluation fails.

                When null (default), the effective value depends on environment intent:
                - editable = true: defaults to true (dev dependencies included)
                - editable = false: defaults to false (production dependencies only)

                This is the recommended way to include development dependencies like
                pytest, ty, type stubs, etc. To add a group ON TOP of an explicit
                `spec` (rather than replacing it), use `groups` instead.
              '';
            };

            groups = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = {};
              description = ''
                Per-member dependency groups to add ON TOP of the final spec —
                whether that spec was auto-computed (via includeGroups) or supplied
                explicitly via `spec`. Unlike `includeGroups` (which only shapes the
                auto-computed spec and is ignored when `spec` is set), `groups`
                always composes.

                Format: attrset keyed by workspace package name, values are group
                names to enable for that member. Each key MUST be a workspace member
                and each group MUST be defined by that member, or evaluation fails.

                Example — give the editable env (which keeps its hand-built `spec`)
                the `research` group without rewriting the spec:
                  groups."my-workspace-root" = [ "research" ];
              '';
            };

            provideDevTools = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = ''
                Advertise this (non-editable) environment as the provider of the
                quality-gate tools (pytest, ty, ruff) that the `checks`, `just`,
                and `pre-commit` modules run against.

                Discovery resolves as:
                - `true`  — use this env for the check tools.
                - `false` — never use this env.
                - null (default) — backward-compatible heuristic: treated as a
                  provider iff `includeGroups == true` (the historical behavior).

                Set this to `true` when you lean an env's groups down with a
                list-form `includeGroups` (e.g. `[ "dev" "test" ]`) but still want it
                to back the checks — the `== true` heuristic would otherwise miss it
                and force a redundant all-groups env to be built.
              '';
            };

            ignoreCollisions = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''
                fnmatch glob patterns for files to ignore during venv creation when
                multiple packages provide the same path with different content.
                Passed to pyproject.nix venvIgnoreCollisions.

                Example: [ "*/site-packages/dbt/*" ]
              '';
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
            # Production environment with only required dependencies
          };
          dev = {
            name = "python-dev";
            editable = true;
            # Include all dependency-groups (e.g., [dependency-groups].dev)
            includeGroups = true;
          };
          ci = {
            name = "python-ci";
            # Non-editable environment for CI checks with dev dependencies
            includeGroups = true;
            # Or use explicit spec for fine-grained control:
            # spec = { "my-package" = ["dev" "test"]; };
          };
        };
      };

      # Secondary uv workspaces (ADR 048)
      extraWorkspaces = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            workspaceRoot = mkOption {
              type = types.path;
              description = ''
                Root of the secondary uv workspace as a Nix path. Must contain
                pyproject.toml and uv.lock (run `uv lock` there to generate it).
              '';
            };

            sourcePreference = mkOption {
              type = types.nullOr (types.enum ["wheel" "sdist"]);
              default = null;
              description = ''
                Prefer wheels or source distributions for this workspace.
                When null (default), follows jackpkgs.python.sourcePreference.
              '';
            };

            extraOverlays = mkOption {
              type = types.listOf types.unspecified;
              default = [];
              description = "Additional overlays to apply to this workspace's Python package set.";
            };

            environments = mkOption {
              type = types.attrsOf (types.submodule {
                options = {
                  name = mkOption {
                    type = types.str;
                    description = "Name of the virtual environment and package output.";
                  };

                  spec = mkOption {
                    type = types.nullOr types.unspecified;
                    default = null;
                    description = ''
                      Custom dependency spec (same semantics as
                      jackpkgs.python.environments.<name>.spec). When null, the
                      spec is computed from includeGroups.
                    '';
                  };

                  includeGroups = mkOption {
                    type = types.nullOr (types.either types.bool (types.listOf types.str));
                    default = null;
                    description = ''
                      Which PEP 735 dependency groups to include when the spec is
                      computed (same semantics as
                      jackpkgs.python.environments.<name>.includeGroups). When
                      null (default), production dependencies only — secondary
                      environments are always non-editable.
                    '';
                  };

                  groups = mkOption {
                    type = types.attrsOf (types.listOf types.str);
                    default = {};
                    description = ''
                      Per-member dependency groups to add ON TOP of the final
                      spec (same semantics as
                      jackpkgs.python.environments.<name>.groups).
                    '';
                  };

                  ignoreCollisions = mkOption {
                    type = types.listOf types.str;
                    default = [];
                    description = ''
                      fnmatch glob patterns for files to ignore during venv
                      creation (same semantics as
                      jackpkgs.python.environments.<name>.ignoreCollisions).
                    '';
                  };
                };
              });
              default = {};
              description = ''
                Plain (non-editable) virtual environments to build from this
                workspace. Environment attribute keys and package names share a
                single namespace with jackpkgs.python.environments and all
                other extraWorkspaces; collisions fail evaluation.
              '';
            };
          };
        });
        default = {};
        description = ''
          Secondary uv workspaces (own workspaceRoot + uv.lock) built alongside
          the primary workspace (ADR 048). Each produces plain virtual
          environments published via jackpkgs.outputs.pythonEnvironments and
          packages.<name>, exactly like primary non-editable environments.

          Deliberately out of scope for secondary workspaces (the submodule
          declares no such options, so setting them fails evaluation): editable
          environments, provideDevTools/checks participation, and devshell hook
          wiring. Those remain exclusive to the primary workspace. Per-workspace
          buildFixes are also out of scope; the global
          jackpkgs.python.buildFixes / setuptools.packages fixes and the
          deterministicBytecode setting apply to every workspace.

          First consumer: a standalone uv project pinned to a different major of
          a dependency, needing a nix-built env with a package override via
          extraOverlays (zeus ADR 265 Decision 4).
        '';
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
        description = "Built Python environments keyed by jackpkgs.python.environments and jackpkgs.python.extraWorkspaces.<name>.environments entries (flat, collision-checked).";
      };

      options.jackpkgs.outputs.pythonDefaultEnv = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Default Python environment derivation when `jackpkgs.python.environments.default` exists.";
      };

      options.jackpkgs.python = {
        pythonPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.python314;
          defaultText = "config.jackpkgs.pkgs.python314";
          description = "Python package to use as base interpreter.";
        };
      };
    });
  };

  config = {
    perSystem = {
      pkgs,
      lib,
      config,
      inputs,
      ...
    }:
      mkIf cfg.enable (let
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

        # The whole uv2nix workspace → pythonSet → env-builder chain lives in
        # lib/python-workspace-scope.nix (ADR 048); the module instantiates one
        # scope for the primary workspace and one per extraWorkspaces entry.
        mkWorkspaceScope = import ../../lib/python-workspace-scope.nix {
          inherit lib;
          inherit (jackpkgsInputs) uv2nix pyproject-nix pyproject-build-systems;
        };

        primaryScope = mkWorkspaceScope {
          inherit pkgs workspaceRoot pyprojectPath uvLockPath;
          python = sysCfg.pythonPackage;
          sourcePreference = cfg.sourcePreference;
          extraOverlays = cfg.extraOverlays;
          buildFixes = cfg.buildFixes;
          setuptoolsPackages = cfg.setuptools.packages;
          deterministicBytecode = cfg.deterministicBytecode;
          darwinSdkVersion = cfg.darwin.sdkVersion;
          # Use flake-root by default, or accept an explicit runtime path string.
          # The overlay expects a runtime-resolvable string, not a Nix store path.
          defaultEditableRoot = "$(${lib.getExe config.flake-root.package})";
          label = "jackpkgs.python";
        };

        inherit (primaryScope) workspace;

        # Secondary workspaces: same chain, per-workspace root / preference /
        # overlays; global buildFixes, setuptools and deterministicBytecode
        # settings apply to every workspace. Error labels carry the workspace
        # key so fail-fast asserts identify the offending entry.
        extraWorkspaceScopes =
          lib.mapAttrs (
            wsKey: wsCfg:
              mkWorkspaceScope {
                inherit pkgs;
                inherit (wsCfg) workspaceRoot extraOverlays;
                python = sysCfg.pythonPackage;
                sourcePreference =
                  if wsCfg.sourcePreference != null
                  then wsCfg.sourcePreference
                  else cfg.sourcePreference;
                buildFixes = cfg.buildFixes;
                setuptoolsPackages = cfg.setuptools.packages;
                deterministicBytecode = cfg.deterministicBytecode;
                darwinSdkVersion = cfg.darwin.sdkVersion;
                label = "jackpkgs.python.extraWorkspaces.${wsKey}";
              }
          )
          cfg.extraWorkspaces;

        # Group-selection combinators (pure; unit-tested in
        # tests/python-group-spec.nix). See lib/python-group-spec.nix.
        groupSpec = import ../../lib/python-group-spec.nix {inherit lib;};

        # Resolve an environment's final dependency spec against a workspace
        # scope (shared by primary and secondary environments):
        # 1. If an explicit spec is provided, use it verbatim; otherwise
        #    compute it from includeGroups (defaulting per environment intent).
        # 2. Validate requested group names (list-form includeGroups is only
        #    meaningful when the spec is computed) and the per-member `groups`,
        #    then compose `groups` onto the base spec. validateGroupSelection
        #    throws on unknown names; on success it returns the composed spec.
        resolveEnvSpec = {
          scope,
          envCfg,
          label,
          includeGroupsDefault ? false,
        }: let
          effectiveIncludeGroups =
            if envCfg.includeGroups != null
            then envCfg.includeGroups
            else includeGroupsDefault;
          baseSpec =
            if envCfg.spec != null
            then envCfg.spec
            else
              scope.computeSpec {
                includeGroups = effectiveIncludeGroups;
              };
        in
          groupSpec.validateGroupSelection {
            depsGroups = scope.workspace.deps.groups;
            includeGroups =
              if envCfg.spec == null
              then effectiveIncludeGroups
              else null;
            inherit (envCfg) groups;
            inherit label;
            payload = groupSpec.composeGroups {
              spec = baseSpec;
              inherit (envCfg) groups;
            };
          };

        pythonWorkspace = {
          inherit (primaryScope) workspace pythonSet defaultSpec computeSpec;
          inherit (primaryScope) mkEnv mkEditableEnv mkEnvForSpec;
        };

        pythonEnvs =
          lib.mapAttrs (
            envKey: envCfg: let
              finalSpec = resolveEnvSpec {
                scope = primaryScope;
                inherit envCfg;
                label = "jackpkgs.python.environments.${envKey}";
                # includeGroups defaults to true for editable envs, false for
                # non-editable (when not explicitly set).
                includeGroupsDefault = envCfg.editable;
              };
            in
              if envCfg.editable
              then
                pythonWorkspace.mkEditableEnv {
                  name = envCfg.name;
                  spec = finalSpec;
                  members = envCfg.members;
                  root = envCfg.editableRoot;
                  inherit (envCfg) ignoreCollisions;
                }
              else
                pythonWorkspace.mkEnv {
                  name = envCfg.name;
                  spec = finalSpec;
                  inherit (envCfg) ignoreCollisions;
                }
          )
          cfg.environments;

        # Secondary environments: always plain (non-editable) envs built from
        # their workspace's scope.
        extraPythonEnvs =
          lib.mapAttrs (
            wsKey: wsCfg: let
              scope = extraWorkspaceScopes.${wsKey};
            in
              lib.mapAttrs (
                envKey: envCfg:
                  scope.mkEnv {
                    name = envCfg.name;
                    spec = resolveEnvSpec {
                      inherit scope envCfg;
                      label = "jackpkgs.python.extraWorkspaces.${wsKey}.environments.${envKey}";
                    };
                    inherit (envCfg) ignoreCollisions;
                  }
              )
              wsCfg.environments
          )
          cfg.extraWorkspaces;

        # Environment package names and attribute keys share one namespace
        # across the primary workspace and every extraWorkspaces entry: the
        # flat jackpkgs.outputs.pythonEnvironments attrset is keyed by env
        # attribute key, and packages.<name> by env name. Duplicates in either
        # namespace fail evaluation (forced via allPythonEnvs below).
        envNames =
          map (e: e.name) (lib.attrValues cfg.environments)
          ++ lib.concatMap (wsCfg: map (e: e.name) (lib.attrValues wsCfg.environments)) (lib.attrValues cfg.extraWorkspaces);
        uniqueEnvNames = lib.unique envNames;
        _envNamesCheck =
          if envNames != uniqueEnvNames
          then throw ("jackpkgs.python: duplicate environment package names detected (across environments and extraWorkspaces): " + builtins.toString envNames)
          else null;

        envKeys =
          lib.attrNames cfg.environments
          ++ lib.concatMap (wsCfg: lib.attrNames wsCfg.environments) (lib.attrValues cfg.extraWorkspaces);
        uniqueEnvKeys = lib.unique envKeys;
        _envKeysCheck =
          if envKeys != uniqueEnvKeys
          then throw ("jackpkgs.python: duplicate environment attribute keys detected (across environments and extraWorkspaces): " + builtins.toString envKeys)
          else null;

        # Flat, collision-checked map of every environment (primary +
        # secondary), keyed by environment attribute key.
        allPythonEnvs = lib.seq _envNamesCheck (
          lib.seq _envKeysCheck (
            pythonEnvs
            // lib.foldl' (acc: envs: acc // envs) {} (lib.attrValues extraPythonEnvs)
          )
        );

        # Validate at most one editable environment
        editableKeys = lib.attrNames (lib.filterAttrs (_: envCfg: envCfg.editable) cfg.environments);
        _editableCountCheck =
          if (lib.length editableKeys) > 1
          then throw ("jackpkgs.python: at most one environment may have editable = true; found: " + lib.concatStringsSep ", " editableKeys)
          else null;

        editableMembers =
          if editableKeys == []
          then []
          else let
            editableKey = lib.head editableKeys;
            envCfg = cfg.environments.${editableKey};
            memberNames =
              if envCfg.members != null
              then envCfg.members
              else builtins.attrNames workspace.workspaceProjects;
          in
            builtins.map (
              memberName: let
                project = workspace.workspaceProjects.${memberName};
                srcDir = project.projectRoot + "/src";
              in {
                name = memberName;
                inherit srcDir;
              }
            )
            memberNames;

        editableNamespaceConflicts =
          if editableMembers == []
          then []
          else namespaceCheck.checkMembers editableMembers;

        _editableNamespaceConsistencyCheck =
          if editableNamespaceConflicts == []
          then null
          else let
            renderConflict = conflict: ''
              shared root '${conflict.rootName}'
                regular-package contributors: ${lib.concatStringsSep ", " conflict.withInit}
                implicit-namespace contributors: ${lib.concatStringsSep ", " conflict.withoutInit}
            '';
            details = lib.concatStringsSep "\n" (builtins.map renderConflict editableNamespaceConflicts);
          in
            throw ''
              jackpkgs.python: editable workspace has inconsistent namespace packaging.

              Mixed PEP 420 implicit namespaces and regular packages were detected at shared package roots.
              This breaks editable workspace imports because a shared-root __init__.py captures the namespace
              and hides sibling workspace members on sys.path.

              ${details}

              Fix: remove shared-root __init__.py files and use PEP 420 consistently across workspace members.
            '';
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

        jackpkgs.outputs.pythonEnvironments = allPythonEnvs;
        # Override pythonDefaultEnv when default environment exists
        jackpkgs.outputs.pythonDefaultEnv =
          if cfg.environments ? default
          then pythonEnvs.default
          else null;

        # Ensure uv is available in the devshell when python module is enabled
        jackpkgs.shell.packages = lib.mkIf cfg.enable [pkgs.uv];

        # Always expose pythonWorkspace as module arg
        _module.args.pythonWorkspace = pythonWorkspace;

        # Publish only non-editable envs as packages.<name>. Secondary
        # environments are always non-editable, so all of them are published.
        packages =
          lib.listToAttrs (
            builtins.filter (x: x != null) (
              lib.mapAttrsToList (
                envKey: envCfg:
                  if envCfg.editable
                  then null
                  else lib.nameValuePair envCfg.name (allPythonEnvs.${envKey})
              )
              cfg.environments
            )
          )
          // lib.listToAttrs (
            lib.concatLists (
              lib.mapAttrsToList (
                wsKey: wsCfg:
                  lib.mapAttrsToList (
                    envKey: envCfg:
                      lib.nameValuePair envCfg.name (allPythonEnvs.${envKey})
                  )
                  wsCfg.environments
              )
              cfg.extraWorkspaces
            )
          );
      });
  };
}
