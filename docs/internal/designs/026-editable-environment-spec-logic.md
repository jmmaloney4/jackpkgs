# ADR-026: Editable Environment Spec Logic — Auto-Include Workspace Members

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

We WILL modify the spec logic for editable environments to **automatically merge all workspace members** into the final spec. This applies whether or not a `spec` is explicitly provided by the user.

### Design Choice: Always Merge for Editable Environments

When `environment.editable = true`:

- All workspace members are automatically merged into the final spec
- User-provided `spec` extras are preserved (they override the base empty list `[]`)
- This ensures all local packages are installed from the checkout, not the Nix store

When `environment.editable = false`:

- Behavior remains unchanged (use provided spec or `workspace.deps.default`)

### Key Insight: Understanding uv2nix's `deps` Structure

After analyzing the uv2nix source code, the `workspace.deps` attribute provides:

```nix
deps = {
  # All workspace members with their optional-dependencies and dev-dependencies
  all = { "member-1" = ["dev" "test" ...]; "member-2" = [...]; ... };
  
  # All workspace members with their optional-dependencies only
  optionals = { "member-1" = [...]; "member-2" = [...]; ... };
  
  # All workspace members with their dev-dependencies (groups) only
  groups = { "member-1" = [...]; "member-2" = [...]; ... };
  
  # All workspace members with their default-groups (tool.uv.default-groups)
  default = { "member-1" = [...]; "member-2" = [...]; ... };
};
```

**Critical finding:** `deps.default` already includes ALL workspace members — each member is a key in the attrset, mapped to its `default-groups` (empty list `[]` if none defined).

### Root Cause Analysis

The bug occurs when users provide an **explicit `spec`** that doesn't include all workspace members:

```nix
environments.dev = {
  editable = true;
  # User only specifies some packages, missing cavins-trident
  spec = { "cavins-nautilus" = ["dev"]; };
};
```

In this case:

1. The editable overlay is applied to all members (default `members = null` means all)
2. But `cavins-trident` is NOT in the spec, so it's not directly installed
3. If `cavins-trident` is a transitive dependency, it gets installed from the Nix store (non-editable)
4. Result: `import cavins.trident` resolves to the stale store copy

### Implementation Approach

#### Option A: Always Merge All Members into Editable Spec (Recommended)

When `editable = true`, automatically merge all workspace members into the final spec, regardless of whether `spec` is null or explicitly provided.

```nix
# Extract all workspace members from deps (any of deps.default/all/optionals/groups works)
allMembersSpec = lib.mapAttrs (_name: _: []) workspace.deps.default;

mkEditableEnv = { name, spec ? null, ... }: let
  userSpec = if spec == null then defaultSpec else spec;
  # ALWAYS merge all members for editable environments
  finalSpec = allMembersSpec // userSpec;  # User overrides take precedence
  ...
```

**Pros:**

- Prevents stale import bugs completely
- Uses stable uv2nix API (`deps.default`)
- User-provided extras are preserved (they override the base `[]`)
- No new options required

**Cons:**

- Slightly larger environments (all members installed)
- May install members the user explicitly didn't want (rare case)

#### Option B: Merge Only When `spec = null`

Only auto-include all members when user doesn't provide an explicit spec.

**Pros:**

- Respects explicit user configuration

**Cons:**

- Doesn't fix the bug when users provide partial specs
- Users must remember to include all members manually

#### Option C: Add `editableAutoIncludeMembers` Option

Add an opt-out option for the merge behavior.

```nix
environments.dev = {
  editable = true;
  editableAutoIncludeMembers = true;  # default: true
  spec = { ... };
};
```

**Pros:**

- Fixes the bug by default
- Power users can opt out if needed

**Cons:**

- More API surface
- Opt-out case is rare

### Chosen Approach: Option A (Always Merge)

We will use **Option A** because:

1. It completely eliminates the stale import bug
2. Uses stable, documented uv2nix API (`workspace.deps`)
3. The behavior matches user expectations for "editable environment"
4. Users who need a subset can use the `members` option to control the editable overlay

The `members` option (which controls the editable overlay) already allows users to restrict which packages get editable treatment. For users who truly want a minimal environment, this provides the escape hatch.

### Detailed Implementation

#### 1. Extract All Workspace Members

```nix
# All workspace members with empty extras (base case)
allMembersSpec = lib.mapAttrs (_name: _: []) workspace.deps.default;
```

#### 2. Update mkEditableEnv Logic

```nix
mkEditableEnv = {
  name,
  spec ? null,
  members ? null,
  root ? null,
}: let
  userSpec = if spec == null then defaultSpec else spec;
  # For editable environments, ALWAYS include all workspace members
  # User-provided extras override the base empty list
  finalSpec = allMembersSpec // userSpec;
  # ... rest unchanged
```

#### 3. Keep Non-Editable Unchanged

```nix
mkEnv = { name, spec ? null }: let
  finalSpec = if spec == null then defaultSpec else spec;  # Unchanged
  # ...
```

### Why This Works

Given:

- `allMembersSpec = { "member-a" = []; "member-b" = []; "member-c" = []; }`
- `userSpec = { "member-a" = ["dev" "test"]; }`

Result:

- `finalSpec = { "member-a" = ["dev" "test"]; "member-b" = []; "member-c" = []; }`

All members are installed, and `member-a` gets its requested extras. The editable overlay (controlled by `members`) then ensures all local packages are installed from the checkout.

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
- **Non-editable environments unchanged**: Only editable environments are affected; non-editable behavior is fully preserved

### Trade-offs

- Slightly larger environments (all members installed even if not directly used)
- Potential for namespace package collisions (pre-existing issue, but more likely to surface)
- Depends on uv2nix `workspace.members` API stability

### Risks & Mitigations

| Risk                                   | Likelihood | Impact | Mitigation                                                                      |
| -------------------------------------- | ---------- | ------ | ------------------------------------------------------------------------------- |
| `workspace.deps` API changes           | Very Low   | Medium | This is a documented, stable uv2nix API; fallback to current behavior if needed |
| Namespace package collisions           | Medium     | Low    | Document; add optional warning; future: namespace config                        |
| Performance regression (larger envs)   | Low        | Low    | Only affects editable envs; acceptable trade-off                                |
| Users want subset of members installed | Low        | Low    | Use `members` option to control editable overlay; rare use case                 |
| Unexpected extras from merge           | Very Low   | Low    | User-provided extras override base; document merge semantics                    |

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
- Would be a semantic change to an existing option

**Why not chosen:** The `members` option has a different purpose; better to fix spec default directly.

### Alternative E — Merge Only When `spec = null`

**Approach:** Only auto-include all members when user doesn't provide an explicit spec (current behavior + fix for null case).

```nix
finalSpec = if spec == null then defaultSpec else spec;  # Keep current
```

**Pros:**

- Minimal change to existing behavior
- Respects explicit user configuration completely

**Cons:**

- Doesn't fix the bug when users provide partial specs (the exact scenario reported)
- Users must manually enumerate all members when customizing extras
- Error-prone — easy to miss a member

**Why not chosen:** This is essentially the current behavior. The bug occurs precisely when users provide partial specs, which this alternative doesn't address.

## Implementation Plan

### Phase 1: Implementation (Verified API)

The uv2nix API has been verified via source code review:

- `workspace.deps.default` is an attrset of all workspace members
- Each key is a package name, each value is a list of default-groups
- This is a stable, documented API

Implementation steps in `modules/flake-parts/python.nix`:

1. **Add `allMembersSpec` definition after `defaultSpec`:**

   ```nix
   defaultSpec = workspace.deps.default;

   # All workspace members with empty extras (for editable merge)
   allMembersSpec = lib.mapAttrs (_name: _: []) defaultSpec;
   ```

2. **Update `mkEditableEnv` to merge all members:**

   ```nix
   mkEditableEnv = {
     name,
     spec ? null,
     members ? null,
     root ? null,
   }: let
     userSpec = if spec == null then defaultSpec else spec;
     # For editable environments, always include all workspace members
     finalSpec = allMembersSpec // userSpec;
     # ... rest unchanged
   ```

3. **No changes to `mkEnv`** (non-editable behavior unchanged)

### Phase 2: Testing

1. Use existing test fixture `tests/fixtures/checks/python-workspace/`
2. Add nix-unit test to verify:
   - Editable env spec includes all members even with partial user spec
   - Non-editable env respects user spec without merging
   - User-provided extras are preserved after merge

### Phase 3: Documentation

1. Update ADR-003 (Python Flake-Parts Module):

   - Document editable spec merge behavior
   - Add example showing partial spec with full member coverage

2. Update README:

   - Clarify "editable environment" semantics
   - Document that all workspace members are always included

3. Add troubleshooting entry:

   - Namespace package collisions
   - How to restrict editable members via `members` option

### Rollout Considerations

- **Breaking change:** Potentially — editable environments will now include all workspace members
- **Impact:** Environments may be slightly larger; unlikely to break existing configs
- **Migration:** None required; existing configs get the fix automatically
- **Escape hatch:** Use `members` option to restrict which packages get editable treatment
- **Rollback:** Revert commit; provide full explicit spec in consumer projects as workaround

## Related

- PR: "Editable python env: default spec should include all uv workspace members"
- ADR-005: Editable vs Non-Editable Environments
- ADR-006: Workspace-Only Python Projects
- uv2nix documentation on workspace overlays

______________________________________________________________________

Author: Cursor (AI assistant)\
Date: 2026-01-25\
PR: #57
