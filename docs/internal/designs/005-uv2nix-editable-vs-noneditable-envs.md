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
- We WILL pass editableRoot as a string (e.g., `$REPO_ROOT`) so that it resolves to a real, non-store path at shell/runtime.
- We WILL keep `workspaceRoot` (and other file inputs) as Nix paths at evaluation time for deterministic workspace loading, file checks, and parsing.

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
  - Mitigation: Keep editableRoot as a plain string like `$REPO_ROOT`; export `REPO_ROOT` in shellHook to the current checkout. Avoid coercing it to a Nix path.
- Risk: Developers try to build the editable env as a package.
  - Mitigation: Module only publishes non-editable envs as packages; document usage clearly.

## Implementation

- In `jackpkgs/modules/flake-parts/python.nix`:
  - Keep `workspaceRoot` resolved to a Nix path using `jackpkgs.projectRoot` and robust joining.
  - In `mkEditableEnv`, pass `overlayArgs.root` as the string `root` (default `$REPO_ROOT`), not a Nix path.
  - Publish only non-editable environments under `packages.<name>`; omit editable envs from package outputs.

- In consumer projects (e.g., zeus):
  - Keep `jackpkgs.projectRoot = ./.;` (or `inputs.self.outPath`) so eval-time path resolution uses real Nix paths.
  - Default developer shell: use `pythonEnvs.editable`; export `REPO_ROOT` in `shellHook`; set `UV_PYTHON = lib.getExe pythonEnvs.editable`.
  - Minimal/CI shells: use non-editable env for `UV_PYTHON` (avoid editable overlay in CI).
  - Do not set editableRoot to a Nix path; keep it as `$REPO_ROOT` or an absolute non-store path string.

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

- ADR-004: Project Root Resolution for flake-parts Modules
- uv2nix workspace docs and overlay implementation (editable overlays and path requirements)

---

Author: Jack Maloney
Date: 2025-10-13
PR: TBD
