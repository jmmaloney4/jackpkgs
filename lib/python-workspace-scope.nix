# mkWorkspaceScope — the single uv2nix workspace → pythonSet → env-builder
# chain used by modules/flake-parts/python.nix (ADR 048).
#
# This is pure code motion of the chain that historically lived inline in the
# python flake-parts module (workspace load, Darwin SDK stdenv override,
# overlay composition, mkVirtualEnv wrappers). Factoring it out lets the
# module instantiate it once for the primary workspace (behavior-preserving)
# and once per `jackpkgs.python.extraWorkspaces.<key>` secondary workspace.
#
# Deep-module contract: callers hand in paths and preferences; all uv2nix /
# pyproject-nix machinery stays behind this interface. The returned scope is:
#
#   {
#     workspace;      # uv2nix loadWorkspace result
#     pythonSet;      # pyproject-nix package set with all overlays applied
#     defaultSpec;    # workspace.deps.default
#     computeSpec;    # { includeGroups ? false } -> spec (bool | [str])
#     mkEnv;          # { name, spec ? null, ignoreCollisions ? [] } -> drv
#     mkEnvForSpec;   # { name, spec, ignoreCollisions ? [] } -> drv
#     mkEditableEnv;  # { name, spec ?, members ?, root ?, ignoreCollisions ? } -> drv
#   }
#
# `label` prefixes every fail-fast error so secondary workspaces report as
# `jackpkgs.python.extraWorkspaces.<key>: ...` while the primary keeps its
# historical `jackpkgs.python: ...` messages.
{
  lib,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
}: {
  pkgs,
  # Base Python interpreter package.
  python,
  # Workspace root as a Nix path.
  workspaceRoot,
  # pyproject.toml / uv.lock locations; default to the workspace root layout.
  # The primary workspace passes its independently-resolved paths here.
  pyprojectPath ? workspaceRoot + "/pyproject.toml",
  uvLockPath ? workspaceRoot + "/uv.lock",
  sourcePreference,
  extraOverlays ? [],
  buildFixes ? {},
  setuptoolsPackages ? [],
  deterministicBytecode ? true,
  darwinSdkVersion ? "15.0",
  # Runtime-resolvable string used as the default root for editable installs
  # (e.g. "$(flake-root)"). Only the primary workspace provides one; editable
  # envs are unsupported for secondary workspaces.
  defaultEditableRoot ? null,
  # Error-message prefix identifying this workspace.
  label ? "jackpkgs.python",
}: let
  # Validate pyproject.toml exists and has either [project] or [tool.uv.workspace]
  pyproject =
    if builtins.pathExists pyprojectPath
    then builtins.fromTOML (builtins.readFile pyprojectPath)
    else {};

  # Light validation: ensure either [project] or [tool.uv.workspace] exists
  pyprojectCheck =
    if !(pyproject ? project || (pyproject ? tool && pyproject.tool ? uv && pyproject.tool.uv ? workspace))
    then throw "${label}: pyproject.toml must contain [project] or [tool.uv.workspace]"
    else null;

  # uv2nix workspace and python set
  workspace = lib.seq pyprojectCheck (
    if builtins.pathExists uvLockPath
    then uv2nix.lib.workspace.loadWorkspace {inherit workspaceRoot;}
    else throw ("${label}: uv.lock not found at " + builtins.toString uvLockPath + " — run 'uv lock' in the project to generate it.")
  );

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
            darwinSdkVersion = darwinSdkVersion;
          };
      }
    else pkgs.stdenv;

  pythonBase = pkgs.callPackage pyproject-nix.build.packages {
    inherit python;
    stdenv = stdenvForPython;
  };

  baseOverlay = workspace.mkPyprojectOverlay {
    inherit sourcePreference;
  };

  packageFixOverlay = import ./python-package-fixes.nix {
    inherit lib;
    packageFixes = buildFixes;
    inherit setuptoolsPackages;
  };

  deterministicBytecodeOverlay = import ./python-deterministic-bytecode.nix {
    inherit lib;
  };

  # Build system overlay should match sourcePreference (wheel OR sdist, not both)
  # Per uv2nix docs: "The build system overlay has the same sdist/wheel distinction as mkPyprojectOverlay"
  overlayList =
    [baseOverlay]
    ++ (
      if sourcePreference == "wheel"
      then [pyproject-build-systems.overlays.wheel]
      else [pyproject-build-systems.overlays.sdist]
    )
    ++ lib.optional deterministicBytecode deterministicBytecodeOverlay
    ++ [packageFixOverlay]
    ++ extraOverlays;

  pythonSet = pythonBase.overrideScope (lib.composeManyExtensions overlayList);

  defaultSpec = workspace.deps.default;

  # Group-selection combinators (pure; unit-tested in
  # tests/python-group-spec.nix). uv2nix provides the two inputs:
  # - workspace.deps.default: each member's default-groups (production)
  # - workspace.deps.groups:  each member's full set of dependency-groups
  #   (PEP 735); the attr VALUE per member is that member's defined groups.
  #
  # Note: PEP 621 optional-dependencies are not supported.
  # Use PEP 735 dependency-groups for development dependencies.
  groupSpec = import ./python-group-spec.nix {inherit lib;};

  # Stable API kept for lib/python-env-selection.nix and any consumer that
  # calls computeSpec directly. includeGroups is bool | [str].
  computeSpec = {includeGroups ? false}:
    groupSpec.resolveSpec {
      depsDefault = workspace.deps.default;
      depsGroups = workspace.deps.groups;
      inherit includeGroups;
    };

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
    ignoreCollisions ? [],
  }: let
    env = addMainProgram (pythonSet.mkVirtualEnv name spec);
  in
    if ignoreCollisions != []
    then env.overrideAttrs (_: {venvIgnoreCollisions = ignoreCollisions;})
    else env;

  mkEnv = {
    name,
    spec ? null,
    ignoreCollisions ? [],
  }: let
    finalSpec =
      if spec == null
      then defaultSpec
      else spec;
  in
    mkEnvForSpec {
      inherit name;
      spec = finalSpec;
      inherit ignoreCollisions;
    };

  mkEditableEnv = {
    name,
    spec ? null,
    members ? null,
    root ? null,
    ignoreCollisions ? [],
  }: let
    finalSpec =
      if spec == null
      then defaultSpec
      else spec;
    # Use the caller-provided default root (flake-root for the primary
    # workspace), or accept an explicit runtime path string. The overlay
    # expects a runtime-resolvable string, not a Nix store path.
    finalRoot =
      if root != null
      then root
      else if defaultEditableRoot != null
      then defaultEditableRoot
      else throw "${label}: editable environments are not supported for this workspace";
    overlayArgs = {root = finalRoot;} // lib.optionalAttrs (members != null) {inherit members;};
    editableSet = pythonSet.overrideScope (workspace.mkEditablePyprojectOverlay overlayArgs);
    env = addMainProgram (editableSet.mkVirtualEnv name finalSpec);
  in
    if ignoreCollisions != []
    then env.overrideAttrs (_: {venvIgnoreCollisions = ignoreCollisions;})
    else env;
in {
  inherit workspace pythonSet defaultSpec computeSpec;
  inherit mkEnv mkEditableEnv mkEnvForSpec;
}
