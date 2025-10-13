# ADR-004: Project Root Resolution for flake-parts Modules

## Status

Accepted

## Context

- Several jackpkgs flake-parts modules need to resolve project-relative files (e.g., `pyproject.toml`, `uv.lock`, workspace roots) at Nix evaluation time.
- Nix primitives like `builtins.pathExists`, `builtins.readFile`, and uv2nix workspace loading require real Nix paths. Using plain strings or runtime shell variables (e.g., `$REPO_ROOT`) at evaluation time leads to errors.
- A recurring pitfall is mixing strings and paths when joining filesystem locations, which can surface as errors such as: "lib.path.append: The first argument is of type string, but a path was expected" during evaluation.

## Decision

- We expose a canonical, evaluation-time project root via a flake-parts option:
  - `jackpkgs.projectRoot : lib.types.path` (default: `inputs.self.outPath`).
  - This is propagated to `perSystem` modules as `_module.args.jackpkgsProjectRoot`.
- All jackpkgs modules that need to resolve project-relative inputs MUST use `_module.args.jackpkgsProjectRoot` to build absolute Nix paths for evaluation-time operations.
- Paths configurable by consumers (e.g., `pyprojectPath`, `uvLockPath`, `workspaceRoot`) SHOULD remain relative strings that are resolved against `jackpkgsProjectRoot` inside the module.
- Minor improvement: path joining within modules MUST be robust against path/string mismatches. Concretely, modules SHOULD:
  - Accept `jackpkgs.projectRoot` as either a Nix path or an absolute path string convertible via `builtins.toPath`.
  - Construct absolute paths by joining in string space and converting with `builtins.toPath`, or by ensuring the base is a Nix path before using `lib.path.append`.

### Scope

- In scope: flake-parts modules in jackpkgs that require evaluation-time filesystem access (e.g., uv2nix Python module).
- Out of scope: runtime shell path discovery (`flake-root` in devshell hooks), which happens after evaluation.

## Consequences

### Benefits
- Deterministic evaluation: modules operate on Nix paths, enabling reliable `builtins.pathExists` and file reads.
- Consistency: a single source of truth for project root resolution reduces duplication and ambiguity.
- Flexibility: consumers can override `jackpkgs.projectRoot` for atypical repository layouts.

### Trade-offs
- Slight configuration surface increase (one option) in exchange for clarity and correctness.
- Consumers must understand the distinction between evaluation-time paths (Nix paths) and runtime shell variables.

### Risks & Mitigations
- Risk: Consumers pass a relative string for `jackpkgs.projectRoot`. Mitigation: the option type is `path`; document absolute override patterns and provide clear errors.
- Risk: Path joins regress to string concatenation errors. Mitigation: enforce robust join logic in modules and add tests/checks.

## Alternatives Considered

### A — Use `inputs.self.outPath` directly in every module
- Pros: Fewer options; no `_module.args`.
- Cons: Hard to override when the project layout differs; duplicates logic across modules.

### B — Resolve at runtime using `flake-root`
- Pros: Flexible for devshells and scripts.
- Cons: Not available during evaluation; cannot be used with `builtins.pathExists` or uv2nix workspace loading.

### C — Require absolute paths for all module options
- Pros: Avoids any joining inside modules.
- Cons: Poor ergonomics; every consumer must calculate absolute paths; hurts reuse.

## Implementation Plan

- Keep `jackpkgs/modules/flake-parts/project-root.nix` exposing:
  - `options.jackpkgs.projectRoot : lib.types.path = inputs.self.outPath`
  - `perSystem._module.args.jackpkgsProjectRoot = config.jackpkgs.projectRoot`
- Ensure consumers (e.g., `python.nix`) resolve relative strings against `_module.args.jackpkgsProjectRoot` using robust join logic:
  - Either ensure base is a Nix path and use `lib.path.append base (subpath)`
  - Or join in string space and convert with `builtins.toPath (baseString + "/" + subpath)`
- Document usage guidance (see below) and add troubleshooting notes.

### API clarification (uv2nix)

- `uv2nix.lib.workspace.loadWorkspace` currently accepts only `{ workspaceRoot = <path>; }`.
- Do not pass `projectRoot` to `loadWorkspace` (unsupported). Instead, ensure `workspaceRoot` is a Nix path constructed from `jackpkgs.projectRoot` and the relative option value.

### Practical caveat: editable environments

- uv2nix’s editable overlay performs path math using `lib.path.*` that assumes path-typed inputs. Our module resolves `workspaceRoot` to a Nix path, but downstream overlay logic can still assert on paths under certain configurations.
- Recommendation:
  - Use the editable environment (`pythonEnvs.editable`) in the main developer shell where editable installs are needed.
  - For minimal or CI-oriented shells (e.g., Pulumi), prefer a non-editable environment (`pythonEnvs.default`) to avoid unnecessary editable overlay path logic.
  - When exporting env vars (e.g., `UV_PYTHON`), pass strings such as `lib.getExe drv` or `builtins.toString drv`, not Nix paths.

### Future changes (shell guidance)

- Editable dev shell:
  - Continue to point `UV_PYTHON` (and similar) at the editable env using string values.
  - Keep `pyprojectPath`, `uvLockPath`, `workspaceRoot` as relative strings; module resolves them against `jackpkgs.projectRoot`.

- Non-editable/minimal dev shell (e.g., Pulumi):
  - Point `UV_PYTHON` at the non-editable env (`pythonEnvs.default`).
  - Avoid editable overlays unless explicitly required.

### Does this undermine `jackpkgs.projectRoot`?

- No. `jackpkgs.projectRoot` still provides the canonical Nix path for evaluation-time path resolution across modules (for `builtins.pathExists`, `readFile`, etc.). The uv2nix API nuance only means we pass a path-typed `workspaceRoot`; we still rely on `projectRoot` to construct that and other absolute paths.

## Usage Guidance

### Typical consumer configuration
```nix
# In your flake-parts config
jackpkgs.projectRoot = inputs.self.outPath;  # or ./. if set at repo root

jackpkgs.python = {
  enable = true;
  environments.default.name = "python-env";
  # Relative strings; module resolves against projectRoot
  pyprojectPath = "./pyproject.toml";
  uvLockPath = "./uv.lock";
  workspaceRoot = ".";
};
```

### Custom repository layout
```nix
# Provide an absolute path when the project root differs
jackpkgs.projectRoot = builtins.toPath "/abs/path/to/project";
```

### Do not
```nix
# Avoid passing relative plain strings for projectRoot
jackpkgs.projectRoot = "../..";  # WRONG — not a Nix path
```

## Troubleshooting

- Error: `lib.path.append: The first argument is of type string, but a path was expected`
  - Cause: Base value was a string, not a Nix path, when joining subpaths at evaluation time.
  - Fix (consumer side): Ensure `jackpkgs.projectRoot` is a Nix path (e.g., `inputs.self.outPath` or a path literal like `./.`) or an absolute string converted via `builtins.toPath`.
  - Fix (module side): Before joining, coerce base to a Nix path or join in string space and apply `builtins.toPath`.

## Related

- `jackpkgs/modules/flake-parts/project-root.nix`: defines `jackpkgs.projectRoot` and wires `_module.args.jackpkgsProjectRoot`.
- `jackpkgs/modules/flake-parts/python.nix`: consumes `_module.args.jackpkgsProjectRoot` to resolve `pyprojectPath`, `uvLockPath`, and `workspaceRoot`.
- ADR-003: uv2nix Flake-Parts Module.

---

Author: Jack Maloney
Date: 2025-10-13
PR: TBD
