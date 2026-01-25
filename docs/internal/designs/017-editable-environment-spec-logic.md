# ADR-017: Editable Environment Spec Logic — Auto-Include Workspace Members

## Status

Proposed

## Context

### Problem

In the `jackpkgs.python` module, when `editable = true` is set on an environment, the `mkEditablePyprojectOverlay` from uv2nix is applied, which instructs the overlay to install workspace members from the local checkout rather than from the Nix store. However, the environment's **spec** (which controls which packages are installed) defaults to `workspace.deps.default` when not explicitly set.

This leads to a subtle but serious bug: if a workspace member is not explicitly listed in the spec, it may still be transitively installed from the Nix store (as a non-editable dependency), causing:

1. **Stale imports**: Code edits in the local checkout do not affect runtime
2. **Confusing debugging**: Tests silently run against stale versions
3. **Broken developer experience**: The term "editable environment" implies all local code is live

**Example from cavinsresearch/zeus:**
```
- Environment: python-nautilus-editable (editable = true)
- Missing from spec: cavins-trident
- Result: `import cavins.trident.core.messages` resolved to /nix/store/... (stale)
```

The user workaround was to manually enumerate all workspace members in the spec, which is tedious and error-prone.

### Current Behavior

```nix
# In python.nix
mkEditableEnv = { name, spec ? null, members ? null, root ? null }: let
  finalSpec = if spec == null then defaultSpec else spec;  # defaultSpec = workspace.deps.default
  # ...
```

The `members` option controls which packages get the editable overlay applied, but the `spec` still determines what's actually installed. If `spec` omits a workspace member, it may be installed from the Nix store if it's a transitive dependency.

### Constraints

- Must maintain backwards compatibility for non-editable environments
- Must work with both single-package projects and workspace-only projects
- Solution should be opt-out or explicit, not silently change behavior
- Must handle namespace package collisions gracefully (or at least document)
- uv2nix's `workspace` object provides member information that can be used

### Prior Art

- ADR-005: Editable vs Non-Editable Environments — established editable overlay mechanics
- ADR-006: Workspace-Only Python Projects — removed `extras` convenience, requires explicit `spec`
- Issue/PR: "Editable python env: default spec should include all uv workspace members"

## Decision

We WILL modify the default spec logic for editable environments to **automatically include all workspace members** when `spec` is null/unset.

### Design Choice: Automatic for Editable Only

When `environment.editable = true` AND `environment.spec = null`:
- The spec defaults to `workspace.deps.default` **merged with** all workspace members
- This ensures all local packages are installed from the checkout, not the Nix store

When `environment.editable = false` OR `environment.spec` is explicitly set:
- Behavior remains unchanged (use provided spec or `workspace.deps.default`)

### Implementation Approach

#### Option A: Derive All-Members Spec from uv2nix Workspace (Recommended)

The uv2nix `workspace` object exposes member information. We can extract package names from the workspace and build a spec that includes all members.

```nix
# Extract all workspace member package names
# workspace.members is an attrset of { <package-name> = <package-derivation>; }
allMembersSpec = lib.mapAttrs (name: _: []) workspace.members;

# For editable environments with null spec, merge all members into default spec
editableDefaultSpec = workspace.deps.default // allMembersSpec;
```

**Pros:**
- Uses authoritative source (uv2nix workspace object)
- No file parsing required in our module
- Handles dynamic workspace configurations correctly

**Cons:**
- Relies on uv2nix internal structure (`workspace.members`)
- May need to verify this API is stable

#### Option B: Parse pyproject.toml Workspace Members Directly

Read `tool.uv.workspace.members` globs from pyproject.toml, resolve them to directories, parse each member's `pyproject.toml` for `project.name`.

**Pros:**
- No dependency on uv2nix internals
- Explicit and auditable

**Cons:**
- Significant implementation complexity (glob resolution, file I/O)
- Duplicates logic that uv2nix already performs
- Potential for drift if uv2nix interprets workspace differently

#### Option C: New Configuration Option (Opt-in)

Add `editableIncludeAllWorkspaceMembers = true` option that users must explicitly enable.

**Pros:**
- No behavior change for existing users
- Explicit opt-in

**Cons:**
- Users must discover and enable this option
- The "right" default for editable envs is to include all members

### Chosen Approach: Option A with Fallback

We will use **Option A** (derive from `workspace.members`) because:
1. It's the most reliable — uses the same source of truth as uv2nix
2. Minimal implementation complexity
3. Automatic behavior matches user expectations for "editable"

If `workspace.members` is not available (API change), we will fall back to the current behavior and emit a warning.

### Detailed Implementation

#### 1. Extract Workspace Members

```nix
# In the mkEditableEnv function or supporting definitions
workspaceMembers = workspace.members or {};
allMembersSpec = lib.mapAttrs (_name: _drv: []) workspaceMembers;
```

#### 2. Define Editable Default Spec

```nix
# Merge default deps with all workspace members (members override to ensure inclusion)
editableDefaultSpec = defaultSpec // allMembersSpec;
```

#### 3. Update mkEditableEnv Logic

```nix
mkEditableEnv = {
  name,
  spec ? null,
  members ? null,
  root ? null,
}: let
  # For editable environments, default spec includes all workspace members
  finalSpec =
    if spec == null
    then editableDefaultSpec  # Changed from: defaultSpec
    else spec;
  # ... rest unchanged
```

#### 4. Keep Non-Editable Unchanged

```nix
mkEnv = { name, spec ? null }: let
  finalSpec = if spec == null then defaultSpec else spec;  # Unchanged
  # ...
```

### API Verification

Need to verify uv2nix exposes `workspace.members`. Based on uv2nix source:
- `loadWorkspace` returns a workspace object
- The workspace object has `deps.default` (confirmed in use)
- Need to check for `members` attribute or equivalent

If `members` is not directly exposed, alternatives:
- Use `workspace.deps.all` if available
- Parse the lock file for workspace member names
- Fall back to current behavior with documentation

### Edge Cases

#### Namespace Package Collisions

When multiple workspace members share a namespace package (e.g., `cavins/__init__.py`), including all members may cause file collisions. This is a pre-existing issue with uv2nix/pip editable installs.

**Mitigation:**
- Document that namespace packages must have byte-identical `__init__.py` files
- Consider adding a warning when multiple members share a top-level package name
- Future: add first-class namespace package configuration

#### Circular Dependencies

Workspace members may have circular dependencies. uv2nix handles this at the overlay level, so no special handling needed in spec logic.

#### Empty Workspace

If `workspace.members` is empty (single-package project), `allMembersSpec` is `{}`, and the behavior is identical to current.

## Consequences

### Benefits

- **Eliminates stale import bugs**: Editable environments always use local checkout for all workspace members
- **Better DX**: "Editable environment" means what users expect — all local code is live
- **Zero additional configuration**: Works automatically when `editable = true`
- **Backwards compatible**: Only affects editable environments with null spec

### Trade-offs

- Slightly larger environments (all members installed even if not directly used)
- Potential for namespace package collisions (pre-existing issue, but more likely to surface)
- Depends on uv2nix `workspace.members` API stability

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `workspace.members` API changes | Low | Medium | Add fallback to current behavior with warning |
| Namespace package collisions | Medium | Low | Document; add optional warning; future: namespace config |
| Performance regression (larger envs) | Low | Low | Only affects editable envs; acceptable trade-off |
| Users want subset of members editable | Low | Low | Can still provide explicit `spec` to override |

## Alternatives Considered

### Alternative A — Require Explicit Spec for Editable Envs

**Approach:** Fail if `editable = true` and `spec = null`, forcing users to be explicit.

**Pros:**
- No ambiguity; user intent is always clear
- No dependency on workspace.members API

**Cons:**
- Poor DX — users must manually enumerate all members
- Error-prone — easy to miss a member and reintroduce the bug
- Extra boilerplate for common case

**Why not chosen:** The common case is "all members editable" — requiring explicit enumeration is tedious and error-prone.

### Alternative B — Add `editableIncludeAllWorkspaceMembers` Option

**Approach:** Add explicit opt-in option.

```nix
environments.dev = {
  editable = true;
  editableIncludeAllWorkspaceMembers = true;  # New option
};
```

**Pros:**
- Explicit opt-in; no surprise behavior changes
- Clearer about what's happening

**Cons:**
- Users must discover and enable this
- The "right" default is to include all — why make users opt in?
- More configuration surface

**Why not chosen:** Auto-including members is the expected behavior for editable environments; requiring opt-in adds friction without benefit.

### Alternative C — Warn But Don't Auto-Include

**Approach:** Detect when workspace members aren't in spec and emit a warning.

**Pros:**
- No behavior change; purely informational
- Users become aware of the issue

**Cons:**
- Doesn't solve the problem — users still get stale imports
- Warning fatigue if users intentionally exclude members

**Why not chosen:** Warnings don't prevent the bug; auto-including solves it.

### Alternative D — Use `members = null` Semantics

**Approach:** The existing `members` option (for editable overlay) already defaults to null meaning "all members." Extend this semantic to spec.

**Pros:**
- Reuses existing option semantics

**Cons:**
- `members` controls overlay application, not spec — conflating them is confusing
- Doesn't address the root cause (spec vs overlay distinction)

**Why not chosen:** The `members` option has a different purpose; better to fix spec default directly.

## Implementation Plan

### Phase 1: Investigate uv2nix API

1. Verify `workspace.members` or equivalent is exposed by uv2nix
2. If not available, determine best alternative (parse lock file, request upstream)
3. Document findings

### Phase 2: Implementation

1. Update `modules/flake-parts/python.nix`:
   - Extract `workspaceMembers` from `workspace` object
   - Create `allMembersSpec` and `editableDefaultSpec`
   - Update `mkEditableEnv` to use `editableDefaultSpec` when `spec = null`
   - Add fallback/warning if `workspace.members` unavailable

2. Update environment building in `pythonEnvs`:
   - Ensure editable environments use the new default spec logic

### Phase 3: Testing

1. Add test fixture with multi-member workspace
2. Verify editable env includes all members in spec
3. Verify non-editable env behavior unchanged
4. Test explicit spec override still works

### Phase 4: Documentation

1. Update ADR-003 (Python Flake-Parts Module) with new editable spec behavior
2. Update README with explanation of editable env behavior
3. Add troubleshooting entry for namespace package collisions

### Rollout Considerations

- **Breaking change:** No — only changes default behavior for editable + null spec
- **Migration:** None required for most users; fixes the bug automatically
- **Rollback:** Revert commit; provide explicit spec in consumer projects as workaround

## Related

- PR: "Editable python env: default spec should include all uv workspace members"
- ADR-005: Editable vs Non-Editable Environments
- ADR-006: Workspace-Only Python Projects
- uv2nix documentation on workspace overlays

---

Author: Cursor (AI assistant)  
Date: 2026-01-25  
PR: #57
