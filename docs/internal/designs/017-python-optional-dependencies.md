# ADR-017: Python Optional Dependencies for CI Checks

## Status

Implemented (2026-01-25)

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

In consumer projects with type stubs in `[project.optional-dependencies].dev`:

```toml
[project.optional-dependencies]
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

### Leverage uv2nix's Built-in Dependency Specs

uv2nix provides four pre-configured dependency specifications:

- `workspace.deps.default` — No optional-dependencies or dependency-groups (production)
- `workspace.deps.optionals` — All optional-dependencies enabled
- `workspace.deps.groups` — All dependency-groups enabled (PEP 735)
- `workspace.deps.all` — All optional-dependencies AND dependency-groups enabled

### New Environment Options

Add two boolean options to environment configuration:

```nix
environments.dev = {
  name = "python-dev";
  editable = true;
  includeOptionalDependencies = true;  # Uses workspace.deps.optionals
  includeGroups = true;                 # Uses workspace.deps.groups
};
```

When both are set, uses `workspace.deps.all`. When neither is set, uses `workspace.deps.default`.

### Automatic CI Environment Selection

The checks module (`checks.nix`) automatically selects the best environment for CI:

1. **Priority 1**: Use explicitly defined 'dev' environment if it exists (non-editable)
2. **Priority 2**: Use any environment with `includeOptionalDependencies = true`
3. **Priority 3**: Create a new environment with all optional dependencies enabled

### API

#### Environment Configuration

```nix
jackpkgs.python.environments = {
  default = {
    name = "my-project";
    # Production deps only (default behavior)
  };
  dev = {
    name = "my-project-dev";
    editable = true;
    includeOptionalDependencies = true;  # [project.optional-dependencies]
    includeGroups = true;                 # [dependency-groups]
  };
  ci = {
    name = "my-project-ci";
    # Non-editable for CI with dev deps
    includeOptionalDependencies = true;
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

1. Added `includeOptionalDependencies` option (bool, default false)
2. Added `includeGroups` option (bool, default false)
3. Added `computeSpec` function that maps options to workspace.deps variants
4. Updated `pythonEnvs` to use `computeSpec` when `spec` is null
5. Exposed `computeSpec` in `pythonWorkspace` for external use

### checks.nix Changes

1. Updated `pythonEnvWithDevTools` to prefer user-defined dev environments
2. Falls back to creating environment with `computeSpec { includeOptionalDependencies = true; includeGroups = true; }`
3. Skips editable environments for CI (they can't be used in pure Nix builds)

## Consequences

### Benefits

1. **Zero-config for common case** — Set `includeOptionalDependencies = true` for dev environments
2. **Works with standard Python packaging** — Uses PEP 621 optional-dependencies and PEP 735 dependency-groups
3. **CI automatically uses dev deps** — The checks module prefers environments with dev dependencies
4. **Fine-grained control available** — Users can still use explicit `spec` for edge cases
5. **Leverages uv2nix infrastructure** — No custom parsing or dependency resolution needed

### Trade-offs

1. **All-or-nothing** — Can't select specific extras (e.g., just "dev" but not "test")
   - Mitigation: Use explicit `spec` for fine-grained control
2. **Implicit behavior in checks.nix** — Auto-selects dev environment
   - Mitigation: Clear priority order documented; users can override

## Alternatives Considered

### Alternative A: Parse pyproject.toml for specific extras

```nix
extras = ["dev", "test"];  # Parse and merge specific optional-dependencies
```

**Pros:** Fine-grained control
**Cons:** Requires TOML parsing, each package may have different extras, complex implementation
**Why not chosen:** uv2nix already provides pre-built specs; complexity not justified

### Alternative B: Automatically include dev deps for editable envs

```nix
# If editable = true, automatically include dev deps
```

**Pros:** Zero-config
**Cons:** Implicit behavior may surprise users; some editable envs may not want dev deps
**Why not chosen:** Too magical; explicit options are clearer

### Alternative C: Require dedicated dev-tools package (ADR-016 pattern)

**Pros:** Works today, explicit
**Cons:** Requires extra workspace member, doesn't use standard dev-dependencies
**Why not chosen:** New options are simpler and align with Python packaging standards

## Related

- [ADR-016: CI Checks Module](./016-ci-checks-module.md) — Documents the checks module
- [ADR-012: uv2nix API Compliance Audit](./012-uv2nix-api-compliance-audit.md) — Documents workspace.deps API
- [ADR-006: Workspace-Only Python Projects](./006-workspace-only-python-projects.md) — Documents spec design

---

Author: Claude (Cursor)
Date: 2026-01-25
PR: cursor/python-optional-dependencies-03e8
