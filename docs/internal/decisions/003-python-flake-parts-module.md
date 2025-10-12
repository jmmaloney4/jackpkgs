# ADR-003: Python (uv2nix) Flake-Parts Module

## Status

Accepted

## Context

Projects like zeus maintain ~187 lines of uv2nix + pyproject-nix boilerplate to build Python environments with extras and editable installs, plus macOS SDK handling and targeted setuptools fixes. This approach is powerful but repetitive. We want a reusable, highly-opinionated flake-parts module that provides a simple, consistent path to Python envs while preserving escape hatches for advanced needs.

This ADR finalizes the design into a general-purpose module named `python` that happens to use uv2nix under the hood today.

Related: designs/003-uv2nix-flake-parts-module.md

## Decision

Introduce a new flake-parts module `jackpkgs.python` that:
- Loads a uv2nix workspace from `pyproject.toml` and `uv.lock`.
- Composes overlays (project, optional build-systems, setuptools fixes, user-provided).
- Exposes helpers to build environments (default/editable) with extras and/or custom specs.
- Publishes each environment as a package, and exports expert `_module.args` for workspace/envs.
- Provides a `pythonDevShell` fragment, optionally contributing it to the shared devshell.

Module name is intentionally generic: it provides “Python environments,” not an opinion on uv2nix itself. uv2nix is an implementation detail that can evolve.

## Implementation Summary

Path: `jackpkgs/modules/flake-parts/python.nix`

- Options (selected):
  - `enable` (bool; default false)
  - `pyprojectPath` (str; default `./pyproject.toml`)
  - `uvLockPath` (str; default `./uv.lock`)
  - `workspaceRoot` (str; default `.`)
  - `pythonPackage` (package; default `pkgs.python312`)
  - `sourcePreference` ("wheel" | "sdist"; default "wheel")
  - `darwin.sdkVersion` (str; default "15.0")
  - `setuptools.packages` (list of str; default `["peewee" "multitasking" "sgmllib3k"]`)
  - `extraOverlays` (list; default [])
  - `environments` (attrset of: `{ name, extras, editable, editableRoot, members, spec, passthru }`)
  - `outputs.exposeWorkspace` (bool; default true), `outputs.exposeEnvs` (bool; default true), `outputs.addToDevShell` (bool; default false)

- Preconditions and assertions:
  - Inputs `uv2nix` and `pyproject-nix` must be present when enabled.
  - `pyproject.toml` must exist and contain `[project].name`.
  - `uv.lock` must exist, with actionable remediation (“run 'uv lock'”).
  - Environment package names must be unique across `environments`.

- Workspace and overlays:
  - Loads workspace via `uv2nix.lib.workspace.loadWorkspace`.
  - Darwin SDK override applied when on macOS (`darwinSdkVersion` default 15.0).
  - Base python set from `pyproject-nix.build.packages`.
  - Overlay composition: project overlay (with `sourcePreference`) + optional `pyproject-build-systems` overlays + `ensureSetuptools` overlay + `extraOverlays`.

- Environment builders (zeus parity):
  - `mkEnv`, `mkEditableEnv`, `mkEnvForSpec`, `specWithExtras`.
  - `meta.mainProgram = "python"` + activation script fixups in `postFixup`.

- Exports:
  - `packages.<env.name>` for each environment.
  - `_module.args.pythonWorkspace` and `_module.args.pythonEnvs` when enabled.
  - Devshell fragment `jackpkgs.outputs.pythonDevShell`; contributes to `jackpkgs.shell.inputsFrom` when `outputs.addToDevShell = true`.

## Inputs (consumer flake.nix)

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/<your-channel>";
  jackpkgs.url = "github:jmmaloney4/jackpkgs";

  # Required for jackpkgs.python when enabled
  pyproject-nix = {
    url = "github:pyproject-nix/pyproject.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  uv2nix = {
    url = "github:adisbladis/uv2nix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.pyproject-nix.follows = "pyproject-nix";
  };
  pyproject-build-systems = {
    url = "github:pyproject-nix/build-system-pkgs";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.pyproject-nix.follows = "pyproject-nix";
    inputs.uv2nix.follows = "uv2nix";
  };
};
```

## Quick Start

Minimal default environment:

```nix
imports = [ inputs.jackpkgs.flakeModules.python ];

jackpkgs.python = {
  enable = true;
  environments.default.name = "python-env";
};
```

Default + Jupyter extras + editable dev env:

```nix
imports = [ inputs.jackpkgs.flakeModules.python ];

jackpkgs.python = {
  enable = true;
  outputs.addToDevShell = true; # include python fragment in the shared devshell
  environments = {
    default = { name = "python-env"; };
    jupyter = { name = "python-env-jupyter"; extras = ["jupyter"]; };
    dev = { name = "python-env-editable"; editable = true; };
  };
};
```

Build/run examples:
- `nix build .#python-env`
- `nix run .#python-env` (works via `meta.mainProgram = "python"`)
- `nix develop` includes the python devshell fragment if `outputs.addToDevShell = true` and you compose `config.jackpkgs.outputs.devShell` in your dev shell.

## Troubleshooting

- Missing `uv.lock`
  - Error: “uv.lock not found … run 'uv lock'”
  - Fix: In your project root (where pyproject.toml lives), run `uv lock`.

- `pyproject.toml` missing `[project].name`
  - Error: “pyproject.toml is missing [project].name”
  - Fix: Add `project.name` to pyproject.toml.

- Duplicate environment names
  - Error: “duplicate environment package names detected”
  - Fix: Ensure each `environments.<key>.name` is unique; consider a naming convention like `<repo>-<variant>`.

- Darwin SDK mismatches
  - Symptom: build failures on macOS related to SDK/headers.
  - Fix: Override `jackpkgs.python.darwin.sdkVersion` to match your Xcode/SDK; default is "15.0".

- Editable mode root
  - Default `editableRoot = "$REPO_ROOT"` expects your devshell to export `REPO_ROOT` (e.g., via flake-root). If unset, pass an explicit path in `editableRoot` or ensure your shell composes a fragment that sets it.

- Wheels vs sdist behavior
  - `sourcePreference` controls preference only; fallbacks depend on upstream availability and the build-systems overlays when present. If a wheel is missing, sdist may be used; document/package-specific nuances may apply.

## Validation Checklist

- Module disabled with no uv files → flake evaluates.
- Module enabled without `uv.lock` → clear assertion with remediation.
- Linux/macOS builds (with zeus-like config) produce envs; `nix run .#<env>` works.
- Editable env reflects workspace changes.
- Setuptools overlay applies to listed packages (check `nativeBuildInputs`).

## Consequences

- Significant reduction in per-repo Nix complexity; standardized patterns; centralized maintenance.
- Abstraction surfaces documented; expert escape hatches available (custom overlays/specs, disabling exports, etc.).

## Rollback

Disable `jackpkgs.python.enable`; return to per-repo implementation. Consumers can pin `jackpkgs` to a prior commit if needed.

