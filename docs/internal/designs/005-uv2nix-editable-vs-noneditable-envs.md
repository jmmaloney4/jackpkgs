# ADR-005: uv2nix Editable vs Non-Editable Environments

## Status

Accepted

## Context

- We are standardizing Python environments via uv2nix. uv2nix supports two modes:
  1) Non-editable envs (plain virtualenvs from resolved wheels/sdists)
  2) Editable envs (workspace packages installed in "editable" mode via `mkEditablePyprojectOverlay`)
- The editable overlay performs path computations with `lib.path.*` and requires inputs that are path-typed or resolve to real filesystem paths at runtime, not Nix store paths.
- Under flakes, evaluation often copies sources into the Nix store, which can accidentally turn path-like values into store paths. uv2nix explicitly rejects editable roots that resolve to the store.
- We need editable environments for developer workflows, but they should not be evaluated as pure flake package outputs where store paths and eval-time purity rules apply most strictly.

## Decision

- We WILL support both environment modes in the jackpkgs Python module:
  - Editable env: for interactive developer shells only.
  - Non-editable env: for flake package outputs and CI/minimal shells.
- We WILL NOT publish editable environments as flake packages. They remain available via `_module.args.pythonEnvs.editable` for dev shells.
- We WILL ensure the editable root is a non-store path by deferring to runtime path discovery. `jackpkgs.python` keeps `editableRoot = "$REPO_ROOT"` by default and the editable shell hook exports that variable using `flake-root`, so editable installs point at the live working tree. Consumers can still override `editableRoot` with an explicit absolute path when needed.
- We WILL require `workspaceRoot` to be provided as a path (typically `./.`) so uv2nix receives a concrete location during evaluation. Other file inputs (`pyprojectPath`, `uvLockPath`) remain relative strings that the module resolves against the project root.

## Consequences

### Benefits
- Editable envs remain available for day-to-day development (hot-reload, local changes).
- Flake checks and package builds avoid brittle path math in editable overlay code paths, improving reliability.
- Clear separation of concerns: eval-time path resolution vs runtime editable workspace roots.

### Trade-offs
- Editable envs do not appear under `packages.<name>`; they must be consumed via dev shells and module args.
- Slightly more configuration awareness needed (which shell uses which env).

### Risks & Mitigations
- Risk: Editable root accidentally becomes a Nix store path.
  - Mitigation: Compose the editable shell hook (or set `editableRoot` explicitly) so `$REPO_ROOT` points at the live checkout before uv runs.
- Risk: Developers try to build the editable env as a package.
  - Mitigation: Module only publishes non-editable envs as packages; document usage clearly.

## Implementation

- In `jackpkgs/modules/flake-parts/python.nix`:
  - Keep `workspaceRoot` resolved to a Nix path using `jackpkgs.projectRoot` and robust joining.
  - In `mkEditableEnv`, pass `overlayArgs.root` as the string `root` (default `$REPO_ROOT`), not a Nix path.
  - Publish only non-editable environments under `packages.<name>`; omit editable envs from package outputs.

- In consumer projects (e.g., zeus):
  - Set `jackpkgs.python.workspaceRoot = ./.;` (or another path literal) so uv2nix reads the intended checkout.
  - Leave `jackpkgs.projectRoot` at its default unless the repository layout requires an override; the editable hook discovers the live checkout at runtime.
  - Default developer shell: use `pythonEnvs.editable` and compose the provided hook (`outputs.addEditableHookToDevShell = true` or `inputsFrom = [ config.jackpkgs.outputs.pythonEditableHook ]`), which exports `REPO_ROOT` and points `UV_PYTHON` at the editable interpreter.
  - Minimal/CI shells: use non-editable env for `UV_PYTHON` (avoid editable overlay in CI).
  - Do not set editableRoot to a Nix path; keep it as `$REPO_ROOT` or an absolute non-store path string.

### Example shellHook (developer shell)

```nix
# Provided hook already exports REPO_ROOT via flake-root; this snippet shows the resulting commands.
repo_root="$(${lib.getExe config.flake-root.package})"
export REPO_ROOT="$repo_root"

# Use editable Python interpreter (string path)
export UV_NO_SYNC="1"
export UV_PYTHON="${lib.getExe pythonEnvs.editable}"
export UV_PYTHON_DOWNLOADS="false"

# Optional: make editable env's bin first
export PATH="${pythonEnvs.editable}/bin:$PATH"
```

## Alternatives Considered

### A — Publish editable envs as packages
- Pros: Uniform access via packages
- Cons: Fails under flakes due to editable root store-path checks and path assertions; brittle and not portable

### B — Make uv2nix accept projectRoot and coerce internally
- Pros: Could centralize path handling
- Cons: Requires upstream changes; still must forbid store paths for editable roots

### C — Avoid editable envs entirely
- Pros: Simplest evaluation model
- Cons: Poor developer experience; no hot-reload/editable installs

## Related

- ADR-004: Project Root Resolution for flake-parts Modules (workspaceRoot is resolved to a Nix path at evaluation time and passed to uv2nix)
- uv2nix workspace docs and overlay implementation (editable overlays and path requirements)

---

Author: Jack Maloney
Date: 2025-10-13
PR: TBD
