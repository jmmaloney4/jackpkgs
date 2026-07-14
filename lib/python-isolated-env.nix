# Reusable helper for building isolated uv2nix Python environments.
#
# `jackpkgs.python` (the flake-parts module) manages one uv workspace root
# and one lockfile. When a tool-specific ecosystem — dbt is the canonical
# example — cannot coexist with the repo's main workspace lock, downstream
# repos need a second uv2nix-built env from a separate lockfile, optionally
# pinned to a different Python minor.
#
# See ADR 044 for the full design rationale.
{
  lib,
  pkgs,
  uv2nix,
  pyprojectNix,
  pyprojectBuildSystems,
}:
# mkIsolatedUvEnv
#
# Build a self-contained Python virtualenv from a dedicated uv workspace
# (its own pyproject.toml + uv.lock), independent of the main
# `jackpkgs.python` workspace.
#
# Arguments (attrset):
#
#   name (str)              — venv derivation name (e.g. "python-dbt")
#   workspaceRoot (path)    — directory containing the isolated uv.lock
#   python (package)        — base interpreter (default: pkgs.python313)
#   sourcePreference (str)  — "wheel" (default) | "sdist"
#   mainProgram (str|null)  — CLI entry point (default: "python")
#   ignoreCollisions (list) — fnmatch globs for venvIgnoreCollisions
#   extraOverlays (list)    — additional overlays appended last
#   darwinSdkVersion (str)  — macOS SDK override (default: "15.0")
#
# Returns: a derivation (the virtualenv package).
#
# Example:
#
#   dbtEnv = jackpkgs.lib.python.mkIsolatedUvEnv {
#     name = "python-dbt";
#     workspaceRoot = ../warehouse;
#     python = pkgs.python313;
#     mainProgram = "dbt";
#     ignoreCollisions = ["*/site-packages/dbt/__init__.py"];
#   };
args @ {
  name,
  workspaceRoot,
  python ? pkgs.python313,
  sourcePreference ? "wheel",
  mainProgram ? "python",
  ignoreCollisions ? [],
  extraOverlays ? [],
  darwinSdkVersion ? "15.0",
}: let
  # ----------------------------------------------------------------
  # Workspace
  # ----------------------------------------------------------------
  workspace = uv2nix.lib.workspace.loadWorkspace {
    inherit workspaceRoot;
  };

  # ----------------------------------------------------------------
  # Darwin SDK override
  # ----------------------------------------------------------------
  # pyproject-nix needs the target macOS SDK version set explicitly;
  # nixpkgs has no way to infer it. jackpkgs.python handles this
  # internally for the main workspace; isolated envs need their own copy.
  stdenv' =
    if pkgs.stdenv.isDarwin
    then
      pkgs.stdenv.override {
        targetPlatform =
          pkgs.stdenv.targetPlatform
          // {darwinSdkVersion = darwinSdkVersion;};
      }
    else pkgs.stdenv;

  # ----------------------------------------------------------------
  # Python package set
  # ----------------------------------------------------------------
  pythonBase = pkgs.callPackage pyprojectNix.build.packages {
    inherit python;
    stdenv = stdenv';
  };

  baseOverlay = workspace.mkPyprojectOverlay {
    inherit sourcePreference;
  };

  buildSystemsOverlay =
    if sourcePreference == "wheel"
    then pyprojectBuildSystems.overlays.wheel
    else pyprojectBuildSystems.overlays.sdist;

  pythonSet =
    pythonBase.overrideScope
    (lib.composeManyExtensions ([baseOverlay buildSystemsOverlay] ++ extraOverlays));

  # ----------------------------------------------------------------
  # Virtualenv
  # ----------------------------------------------------------------
  addMainProgram = drv:
    drv.overrideAttrs (old: {
      meta =
        (old.meta or {})
        // {mainProgram = mainProgram;};
    });

  rawEnv = pythonSet.mkVirtualEnv name workspace.deps.default;

  envWithCollisions =
    if ignoreCollisions != []
    then
      rawEnv.overrideAttrs
      (_: {venvIgnoreCollisions = ignoreCollisions;})
    else rawEnv;
in
  addMainProgram envWithCollisions
