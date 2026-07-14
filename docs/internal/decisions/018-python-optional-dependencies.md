# ADR-018: Python Dependency Groups for CI Checks (PEP 735 Only)

## Status

Implemented (2026-01-25), Updated (2026-01-26)

## Context

### Problem Statement

The jackpkgs Python module builds environments from uv workspaces via uv2nix, but only exposes production dependencies as packages. Dev dependencies (pytest, mypy, type stubs like `types-Authlib`, etc.) are available in the devshell but cannot be reliably used in:

- Nix flake checks (isolated Nix build environments)
- CI/CD derivations
- Hermetic testing environments

This creates a gap where CI checks either:

1. Must mix nixpkgs packages with uv2nix packages (version mismatches, incomplete type stubs)
2. Require workarounds like moving type stubs to production dependencies (violates separation of concerns)

### Real-World Impact

In consumer projects with type stubs in `[dependency-groups]`:

```toml
[dependency-groups]
dev = [
    "pytest>=8.0.0",
    "mypy>=1.11.0",
    "types-Authlib>=1.3.0.0",  # ← type stubs for authlib
]
```

Running `nix flake check` with mypy would fail because type stubs aren't in the environment:

```
error: Library stubs not installed for "authlib.integrations.requests_client"  [import-untyped]
```

### Previous Workarounds

1. **Move type stubs to production deps** — pollutes production with dev-only packages
2. **ADR-016's dedicated dev-tools package pattern** — requires extra workspace members
3. **Mix nixpkgs with uv2nix** — version mismatches, incomplete coverage

## Decision

### Leverage uv2nix's PEP 735 Dependency Groups

This module supports **PEP 735 dependency groups only**. PEP 621 optional dependencies are not supported.

uv2nix provides two relevant dependency specifications:

- `workspace.deps.default` — No dependency-groups (production only)
- `workspace.deps.groups` — All dependency-groups enabled (PEP 735)

### Dependency Groups Across Workspace Members

When using uv workspaces, dependency groups are **aggregated across all workspace members**:

- `workspace.deps.groups` includes all `[dependency-groups]` and `[tool.uv.dev-dependencies]` from:
  - The workspace root `pyproject.toml`
  - All local workspace member projects

This means defining `[dependency-groups].dev` at the workspace root makes those dependencies available to all member projects, which is the recommended pattern for shared dev dependencies (pytest, mypy, ruff, type stubs, etc.).

### New Environment Option: `includeGroups`

Add a tri-state boolean option to environment configuration:

```nix
environments.dev = {
  name = "python-dev";
  editable = true;
  includeGroups = null;  # Default: true for editable, false for non-editable
};
```

When `includeGroups` is:

- `null` (default): Follows environment intent (true for editable, false for non-editable)
- `true`: Explicitly includes all dependency groups
- `false`: Explicitly excludes all dependency groups

### Automatic CI Environment Selection

The checks module (`checks.nix`) automatically selects the best environment for CI:

1. **Priority 1**: Use explicitly defined 'dev' environment if it's non-editable and has `includeGroups = true`
2. **Priority 2**: Use any non-editable environment with `includeGroups = true`
3. **Priority 3**: Create a new environment with all dependency groups enabled

### API

#### Environment Configuration

```nix
jackpkgs.python.environments = {
  default = {
    name = "my-project";
    # Production deps only (includeGroups defaults to false for non-editable)
  };
  dev = {
    name = "my-project-dev";
    editable = true;
    # includeGroups defaults to true for editable environments
  };
  ci = {
    name = "my-project-ci";
    # Non-editable for CI with dev deps
    includeGroups = true;  # Explicitly enable for CI
  };
};
```

#### Explicit Spec Override

For fine-grained control, the `spec` option still overrides all other spec options:

```nix
environments.custom = {
  name = "my-custom";
  spec = pythonWorkspace.defaultSpec // {
    "my-package" = ["dev" "test"];
  };
};
```

## Implementation

### python.nix Changes

1. Removed `includeOptionalDependencies` option (PEP 621 not supported)
2. Changed `includeGroups` from bool to nullable bool (default `null`)
3. Added `effectiveIncludeGroups` computation: defaults to true for editable, false for non-editable
4. Updated `computeSpec` function to only accept `includeGroups` parameter
5. Exposed `computeSpec` in `pythonWorkspace` for external use

### checks.nix Changes

1. Updated `pythonEnvWithDevTools` to use `isCiEnvCandidate` predicate (non-editable + `includeGroups = true`)
2. Falls back to creating environment with `computeSpec { includeGroups = true; }`
3. Skips editable environments for CI (they can't be used in pure Nix builds)

## Consequences

### Benefits

1. **Opinionated defaults** — Editable envs automatically include dev deps, production envs don't
2. **Works with standard Python packaging** — Uses PEP 735 dependency-groups
3. **CI automatically uses dev deps** — The checks module prefers environments with dev dependencies
4. **Fine-grained control available** — Users can still use explicit `spec` for edge cases
5. **Leverages uv2nix infrastructure** — No custom parsing or dependency resolution needed
6. **Workspace-level dev dependencies** — Define shared dev dependencies once at workspace root

### Trade-offs

1. **All-or-nothing** — Can't select specific groups (e.g., just "dev" but not "test")
   - Mitigation: Use explicit `spec` for fine-grained control
2. **Implicit behavior in checks.nix** — Auto-selects dev environment
   - Mitigation: Clear priority order documented; users can override
3. **PEP 621 not supported** — Only PEP 735 dependency groups
   - Mitigation: PEP 735 is the modern standard for dev dependencies; most projects should migrate

## Alternatives Considered

### Alternative A: Support both PEP 621 and PEP 735

```nix
includeOptionalDependencies = true;  # PEP 621
includeGroups = true;                # PEP 735
```

**Pros:** Maximum flexibility
**Cons:** Confusing API with two similar options; PEP 621 optional-dependencies are for package consumers, not maintainers
**Why not chosen:** PEP 735 is the recommended standard for development dependencies; simpler API with single option

### Alternative B: Parse pyproject.toml for specific groups

```nix
groups = ["dev", "test"];  # Parse and merge specific dependency groups
```

**Pros:** Fine-grained control
**Cons:** Requires TOML parsing, each package may have different groups, complex implementation
**Why not chosen:** uv2nix already provides pre-built specs; complexity not justified

### Alternative C: Require dedicated dev-tools package (ADR-016 pattern)

**Pros:** Works today, explicit
**Cons:** Requires extra workspace member, doesn't use standard dev-dependencies
**Why not chosen:** New options are simpler and align with Python packaging standards

## Related

- [ADR-016: CI Checks Module](./016-ci-checks-module.md) — Documents the checks module
- [ADR-012: uv2nix API Compliance Audit](./012-uv2nix-api-compliance-audit.md) — Documents workspace.deps API
- [ADR-006: Workspace-Only Python Projects](./006-workspace-only-python-projects.md) — Documents spec design

______________________________________________________________________

Author: Claude (Cursor)
Date: 2026-01-25, Updated: 2026-01-26
PR: cursor/python-optional-dependencies-03e8
