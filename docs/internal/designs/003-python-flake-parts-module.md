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
- Publishes non-editable environments as packages and exports expert `_module.args` for workspace/envs.
- Provides devshell fragments for the base interpreter and optional editable env hook.

Module name is intentionally generic: it provides “Python environments,” not an opinion on uv2nix itself. uv2nix is an implementation detail that can evolve.

## Implementation Summary

Path: `jackpkgs/modules/flake-parts/python.nix`

- Options (selected):
  - `enable` (bool; default false)
  - `pyprojectPath` (str; default `./pyproject.toml`)
  - `uvLockPath` (str; default `./uv.lock`)
  - `workspaceRoot` (path; required when enabled, typically `./.`)
  - `sourcePreference` ("wheel" | "sdist"; default "wheel")
  - `darwin.sdkVersion` (str; default "15.0")
  - `setuptools.packages` (list of str; default `["peewee" "multitasking" "sgmllib3k"]`)
  - `extraOverlays` (list; default [])
  - `environments` (attrset of: `{ name, spec, editable, editableRoot, members, passthru }`)
    - **`spec` is optional** (defaults to `workspace.deps.default`) — explicit dependency specification for customization
    - **`editable`**: at most one environment may have `editable = true`

- Per-system additions:
  - `jackpkgs.python.pythonPackage` (package; default `pkgs.python312`)
  - Read-only output `jackpkgs.outputs.pythonEditableHook` (automatically included in devshell)

- Preconditions and assertions:
  - Inputs `uv2nix` and `pyproject-nix` must be present when enabled.
  - `workspaceRoot` must be set to a path (for example `./.`); the module asserts if it is unset or not a path.
  - `pyproject.toml` must exist and contain either `[project].name` OR `[tool.uv.workspace]` (workspace-only mode).
  - `uv.lock` must exist, with actionable remediation ("run 'uv lock'").
  - Environment package names must be unique across `environments`.
  - **At most one environment may have `editable = true`**; fails with clear error if violated.

- Workspace and overlays:
  - Loads workspace via `uv2nix.lib.workspace.loadWorkspace`.
  - Darwin SDK override applied when on macOS (`darwinSdkVersion` default 15.0).
  - Base python set from `pyproject-nix.build.packages`.
  - Overlay composition order (left-to-right, later takes precedence):
    1. `pyproject-build-systems.overlays.{wheel,sdist}` — Provides PEP-517 build systems (setuptools, maturin, hatchling, etc.) and build fixups
    2. `baseOverlay` (user's workspace via `workspace.mkPyprojectOverlay`) — User's locked runtime dependencies from `uv.lock` (**AUTHORITATIVE**)
    3. `ensureSetuptools` — Targeted fixes for packages that need setuptools in `nativeBuildInputs`
    4. `cfg.extraOverlays` — User-provided custom overlays
  - **Rationale for ordering:** Build-systems overlays provide essential build-time dependencies not locked by `uv`, but should **not override** user's runtime dependencies. User's `uv.lock` is the single source of truth for runtime dependencies; applying `baseOverlay` after build-systems ensures user's locked versions take precedence. `ensureSetuptools` applies last (except `extraOverlays`) to ensure targeted fixes aren't accidentally removed.
  - **Historical note:** Prior to issue [#78](https://github.com/jmmaloney4/jackpkgs/issues/78), `baseOverlay` was applied **before** build-systems overlays, causing user's locked dependencies to be overridden by `pyproject-build-systems`'s own workspace packages (which include transitive build deps like `typing-extensions` for `pydantic-core` builds). This defeated the purpose of lock files and was corrected by reversing the order.

- Environment builders (simplified from zeus):
  - `mkEnv`, `mkEditableEnv`, `mkEnvForSpec`.
  - `meta.mainProgram = "python"` + activation script fixups in `postFixup`.
  - **Breaking change (ADR-006)**: `extras` and `specWithExtras` removed entirely; all environments require explicit `spec` configuration.

- Exports:
  - `packages.<env.name>` for each non-editable environment.
  - `_module.args.pythonWorkspace` (always exposed for use in environment specs).
  - Editable environment automatically included in devshell via `jackpkgs.outputs.pythonEditableHook` (sets PATH, UV_PYTHON, REPO_ROOT).

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

Minimal default environment (uses all dependencies from uv.lock):

```nix
imports = [ inputs.jackpkgs.flakeModules.python ];

jackpkgs.python = {
  enable = true;
  workspaceRoot = ./.;
  environments.default = {
    name = "python-env";
  };
};
```

Multiple environments with explicit specs:

```nix
imports = [ inputs.jackpkgs.flakeModules.python ];

perSystem = { pythonWorkspace, ... }: {
  jackpkgs.python = {
    enable = true;
    workspaceRoot = ./.;
    environments = {
      default = {
        name = "python-env";
        spec = pythonWorkspace.defaultSpec;
      };
      jupyter = {
        name = "python-env-jupyter";
        spec = pythonWorkspace.defaultSpec // {
          "my-package" = ["jupyter"];
        };
      };
      dev = {
        name = "python-env-editable";
        editable = true;  # Automatically included in devshell
        spec = pythonWorkspace.defaultSpec // {
          "my-package" = ["dev" "test"];
        };
      };
    };
  };
};
```

Custom interpreter version (per-system):

```nix
perSystem = { pkgs, ... }: {
  jackpkgs.python.pythonPackage = pkgs.python311;
};
```

Workspace-only configuration (no `[project]` section):

```nix
imports = [ inputs.jackpkgs.flakeModules.python ];

perSystem = { config, pythonWorkspace, ... }: {
  jackpkgs.python = {
    enable = true;
    workspaceRoot = ./.;
    environments = {
      dev = {
        name = "python-dev";
        spec = pythonWorkspace.defaultSpec // {
          "package-a" = ["dev" "test"];
          "package-b" = ["dev"];
        };
      };
    };
  };
};
```

Build/run examples:
- `nix build .#python-env`
- `nix run .#python-env` (works via `meta.mainProgram = "python"`)
- `nix develop` automatically includes the editable environment when one is defined.

## Troubleshooting

- Missing `uv.lock`
  - Error: “uv.lock not found … run 'uv lock'”
  - Fix: In your project root (where pyproject.toml lives), run `uv lock`.

- Missing `workspaceRoot`
  - Error: “workspaceRoot (path) is required when jackpkgs.python.enable = true …”
  - Fix: Set `jackpkgs.python.workspaceRoot = ./.;` (or an absolute path) so the module can pass a real Nix path to uv2nix.

- `pyproject.toml` missing `[project]` or `[tool.uv.workspace]`
  - Error: "pyproject.toml must contain [project] or [tool.uv.workspace]"
  - Fix: Add `[project]` section with `name` field, or add `[tool.uv.workspace]` section for workspace-only repos.

- Duplicate environment names
  - Error: "duplicate environment package names detected"
  - Fix: Ensure each `environments.<key>.name` is unique; consider a naming convention like `<repo>-<variant>`.

- Multiple editable environments
  - Error: "at most one environment may have editable = true; found: ..."
  - Fix: Only one environment can be editable. Choose which environment should be your development environment and set `editable = true` only for that one.

- Darwin SDK mismatches
  - Symptom: build failures on macOS related to SDK/headers.
  - Fix: Override `jackpkgs.python.darwin.sdkVersion` to match your Xcode/SDK; default is "15.0".

- Editable mode root
  - Default `editableRoot = "$REPO_ROOT"` is set automatically via flake-root in the devshell.
  - Editable environments are not exported under `packages`; they're automatically available in `nix develop`.

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
