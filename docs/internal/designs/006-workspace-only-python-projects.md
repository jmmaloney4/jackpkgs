# ADR-006: Workspace-Only Python Projects

## Status

Accepted (Simplified Implementation - 2025-10-16)

## Context

### Problem

The `jackpkgs.python` module currently requires `pyproject.toml` to contain `[project].name`. This prevents workspace-only repositories (monorepos using `[tool.uv.workspace]` without a root distribution) from using the module, forcing users to either:
- Create a dummy root package with fake metadata
- Manually maintain uv2nix boilerplate outside the module
- Switch away from editable development environments

Additionally, the `extras` convenience option creates ambiguity in workspace-only projects where there's no obvious "target" package for applying extras. This leads to fragile default behavior (picking the first package) that is implicit and error-prone.

### Constraints

- Must align with uv workspace semantics (workspace-only projects are valid and increasingly common)
- Solution must be simple and explicit
- No ambiguous or "magic" default behaviors
- All projects should use the same configuration pattern

### Prior Art

- Issue #72: "Allow workspace-only pyproject without requiring [project].name"
- ADR-003: Python (uv2nix) Flake-Parts Module — established the current `[project].name` requirement
- ADR-004: Project Root Resolution — established path handling for workspace files
- ADR-005: Editable vs Non-Editable Environments — established editable overlay mechanics

### Understanding Extras and Dependency Specs

Python extras are **package-specific** optional dependencies defined in a package's `pyproject.toml`:

```toml
[project]
name = "my-package"

[project.optional-dependencies]
dev = ["pytest", "black"]
jupyter = ["jupyter", "ipykernel"]
```

Installed via: `pip install my-package[dev]` or `uv pip install my-package[jupyter]`.

In uv2nix, `workspace.deps.default` is a dependency specification (attrset) passed to `mkVirtualEnv`:

```nix
{
  "my-package" = ["dev"];  # Install my-package with dev extra
  "numpy" = [];            # Install numpy without extras
}
```

This translates to: `uv pip install my-package[dev] numpy`.

The current `jackpkgs.python` module provides a convenience `extras` option that applies extras to a single target package (determined by `projectName`). In projects with a root distribution, this target is obvious (the root). In workspace-only projects, there is no root — only members — so picking a "default" extras target is arbitrary and error-prone.

## Decision

We WILL simplify to **workspace-only Python projects** by:

1. **Removing `extras` support entirely**: The `extras` convenience option is removed. ALL users must use explicit `spec` configuration.

2. **Relaxing validation**: Accept `pyproject.toml` files with `[tool.uv.workspace]` or `[project]` section (but don't extract or use `projectName`).

3. **No new configuration options**: No `workspaceName`, no `includeRootDistribution`, no `extrasTarget`, no `extras`. Keep the API surface minimal.

4. **Clear error messages**: When `spec` is null, throw an actionable error directing users to provide explicit spec.

### Rationale

- **Explicit > Implicit**: Forces users to see exactly what packages and extras are in their environment
- **Removes ~60 lines of logic**: Simplifies maintenance by removing conditional behavior, target selection, and fallback logic
- **Single pattern**: One clear way to configure environments (explicit `spec`)
- **Future-proof**: uv workspaces are the recommended pattern; this enforces best practices

### Scope

- **In scope**: Validation relaxation, removing extras logic, clear error messaging, documentation updates
- **Out of scope**: New configuration options, automatic extras target inference, backwards compatibility layer, uv2nix changes

### Implementation Details

#### Validation Logic (Simplified)

```nix
# Light validation: ensure either [project] or [tool.uv.workspace] exists
if !(pyproject ? project || (pyproject ? tool && pyproject.tool ? uv && pyproject.tool.uv ? workspace))
then throw "jackpkgs.python: pyproject.toml must contain [project] or [tool.uv.workspace]"
else null

# No projectName extraction needed
```

#### Spec Requirement

All environments must provide explicit `spec` configuration. The `extras` option and related logic (`ensureList`, `specWithExtras`, `targetName`, `projectName`) are removed entirely.

#### Environment Configuration Examples

**Before (removed):**
```nix
jackpkgs.python = {
  enable = true;
  workspaceRoot = ./.;
  
  environments.dev = {
    name = "python-dev";
    extras = ["dev" "test"];  # REMOVED: No longer supported
  };
};
```

**After (only supported pattern):**
```nix
jackpkgs.python = {
  enable = true;
  workspaceRoot = ./.;
  
  environments.dev = {
    name = "python-dev";
    spec = workspace.deps.default // {
      "zeus-core" = ["dev" "test"];
      "zeus-api" = ["dev"];
    };
  };
};
```

**Workspace-only (via pythonWorkspace arg):**
```nix
perSystem = { config, pythonWorkspace, ... }: {
  jackpkgs.python = {
    enable = true;
    workspaceRoot = ./.;
    
    environments.dev = {
      name = "python-dev";
      spec = pythonWorkspace.defaultSpec // {
        "zeus-core" = pythonWorkspace.defaultSpec."zeus-core" ++ ["dev"];
      };
    };
  };
};
```

## Consequences

### Benefits

- **Unlocks workspace-only repos**: Monorepos can now use `jackpkgs.python` without creating dummy root packages
- **Explicit > Implicit**: Forces users to think about which packages get which extras in multi-package workspaces
- **Radically simpler implementation**: Removes ~60 lines of conditional logic, validation, and fallback behavior
- **Single pattern**: One clear way to configure environments (explicit `spec`)
- **Easier maintenance**: Less code, fewer edge cases, no backwards compatibility burden
- **Aligns with uv semantics**: Workspace-only projects are first-class in uv; they should be in jackpkgs too

### Trade-offs

- **Breaking change**: Existing configs using `extras` must migrate to explicit `spec`
- **Slightly more verbose config** (but clearer and more explicit)
- **Learning curve**: Users need to understand `workspace.deps.default` structure to write explicit specs
- **No convenience option**: Users must always write full spec configuration

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Users confused by `spec` syntax | Medium | Low | Provide clear examples in README and error messages; expose `pythonWorkspace.defaultSpec` for introspection |
| Editable envs break in workspace-only mode | Low | High | Test editable envs explicitly; uv2nix's editable overlay should already handle missing root |
| `projectName = "workspace"` causes collisions | Low | Low | Name is only used in passthru; document that it's a placeholder in workspace-only mode |

## Alternatives Considered

### Alternative A — Add `extrasTarget` option

**Approach:**
```nix
environments.dev = {
  name = "dev";
  extrasTarget = "zeus-core";  # Explicit target for extras
  extras = ["dev"];
};
```

**Pros:**
- Preserves the `extras` convenience API
- Explicit target avoids ambiguity

**Cons:**
- Adds a new option (more API surface)
- Still requires users to specify a target, so not much more convenient than full `spec`
- Doesn't handle "apply extras to multiple packages" use case
- Creates confusion between per-env `extrasTarget` and top-level concepts

**Why not chosen:** If we're requiring explicit configuration anyway, full `spec` is more flexible and doesn't add new options.

### Alternative B — Auto-detect "main" package

**Approach:** Use heuristics (first alphabetically, largest, etc.) to pick a default extras target.

**Pros:**
- Minimal user configuration

**Cons:**
- Arbitrary and fragile (what if package names or structure change?)
- Implicit behavior leads to surprises
- Doesn't handle multi-package extras properly

**Why not chosen:** Violates the principle of explicit configuration; too much "magic."

### Alternative C — Add `workspaceName` and `includeRootDistribution`

**Approach:** Allow users to configure workspace-level metadata and control root inclusion in editable envs.

**Pros:**
- Flexible control over workspace behavior

**Cons:**
- Adds multiple new options
- `lib.baseNameOf` default is impure
- Unclear why workspace name is needed (only used in passthru)
- `includeRootDistribution` is unnecessary if "everything is a workspace"

**Why not chosen:** Over-engineered; adds complexity without clear value.

### Alternative D — Require stub root package

**Approach:** Document pattern for creating a minimal root `[project]` with fake metadata.

**Pros:**
- Zero code changes

**Cons:**
- Forces users to maintain fake metadata
- Clutters repository with non-functional package
- Goes against uv's workspace-only design

**Why not chosen:** Doesn't solve the underlying problem; just works around it.

## Implementation Plan

### Phase 1: Code Changes
1. Update validation logic in `modules/flake-parts/python.nix`:
   - Add `hasProject` and `hasWorkspace` checks
   - Relax `projectName` validation to accept workspace-only mode
   - Add error in `specWithExtras` when `extras` is used without `[project]`
2. Test locally with a workspace-only fixture

### Phase 2: Documentation
1. Update `README.md`:
   - Remove `[project].name` requirement from python module docs
   - Add workspace-only example with explicit `spec`
   - Clarify that `extras` requires a root distribution
2. Update `docs/internal/designs/003-python-flake-parts-module.md`:
   - Document workspace-only support
   - Update constraints section
   - Add examples for both modes
3. Create this ADR (006)

### Phase 3: Validation
1. Build test environments (editable + non-editable) in workspace-only repo
2. Verify error message clarity when `extras` is misused
3. Confirm backwards compatibility with existing root-distribution repos

### Rollout Considerations
- **Breaking change risk**: Low — only affects undocumented fallback behavior
- **Migration path**: Users relying on `extras` in workspace-only repos will get clear error with migration example
- **Rollback**: Simply revert validation changes; no persistent state affected

## Related

- Issue: [#72 — Allow workspace-only pyproject without requiring [project].name](https://github.com/jmmaloney4/jackpkgs/issues/72)
- ADR-003: Python (uv2nix) Flake-Parts Module — establishes current module design
- ADR-004: Project Root Resolution — path handling for workspace files
- ADR-005: Editable vs Non-Editable Environments — editable overlay mechanics

---

Author: Jack Maloney (via AI assistant)  
Date: 2025-10-16  
Issue: #72

