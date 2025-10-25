# ADR-013: Python Transitive Dependency Overlay Solution

## Status

Proposed

## Context

### The Problem

Issue #78 revealed a critical limitation in our Python module: **transitive dependencies from `uv.lock` are not overlaid**, causing version mismatches between locked versions and nixpkgs versions.

**Root Cause:** uv2nix's `mkPyprojectOverlay` only overlays packages specified in the `spec` parameter (typically `workspace.deps.default`, which contains only **direct** dependencies from `pyproject.toml`). Transitive dependencies—even though present in `uv.lock`—are not included in the overlay and fall back to nixpkgs versions.

**Example Failure:**
```python
# User's uv.lock specifies typing-extensions 4.15.0
# But nixpkgs provides 4.13.2
# Import fails because Sentinel was added in 4.14.0

from typing_extensions import Sentinel
# ImportError: cannot import name 'Sentinel' from 'typing_extensions'
```

### Evidence

**Test in affected user project:**
```bash
$ nix eval --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    uv2nix = flake.inputs.jackpkgs.inputs.uv2nix;
    workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
  in
    builtins.hasAttr "typing-extensions" workspace.deps.default
'
false  # ← Not in workspace.deps.default (not a direct dependency)
```

**But it IS in uv.lock:**
```toml
name = "typing-extensions"
version = "4.15.0"
source = { registry = "https://pypi.org/simple" }
```

### Source Code Analysis

**File:** [`pyproject-nix/uv2nix/lib/overlays.nix:54-87`](https://github.com/pyproject-nix/uv2nix/blob/e6e728d9719e989c93e65145fe3f9e0c65a021a2/lib/overlays.nix#L54-L87)

```nix
resolved = lock1.resolveDependencies {
  lock = lock1.filterConflicts {
    lock = uvLock;
    inherit spec;
  };
  environ = environ';
  dependencies = attrNames spec;  # ← ONLY direct dependencies!
};

# Creates overlay ONLY for resolved packages
mapAttrs (
  name: package:
  if localProjects ? ${name} then
    callPackage (build.local { ... }) { }
  else
    callPackage (buildRemotePackage package) { }
) resolved;  # ← Only packages in 'resolved' get overlaid
```

**The flow:**
1. `spec` = `workspace.deps.default` (direct dependencies from pyproject.toml)
2. `dependencies = attrNames spec` (only direct dependency names)
3. `resolveDependencies` resolves only these direct dependencies
4. `mapAttrs` creates overlay entries only for `resolved` packages
5. **Transitive dependencies:**
   - ✅ Present in `uv.lock`
   - ❌ NOT in `workspace.deps.default`
   - ❌ NOT in `resolved`
   - ❌ NOT overlaid
   - ❌ Fall back to `pythonBase` (nixpkgs versions)

### Impact

**Affects any package where:**
1. It's a transitive dependency (not directly in pyproject.toml)
2. AND it's in uv.lock
3. AND the locked version differs from nixpkgs version
4. AND the version difference causes compatibility issues

**Common affected packages:**
- `typing-extensions` (transitive via pydantic-core, pydantic, fastapi)
- `setuptools` (transitive via many build systems)
- `wheel` (transitive via many build systems)
- `tomli` (transitive via many build systems)
- Any other common transitive dependency with version mismatches

### Constraints

- Must maintain compatibility with existing uv2nix APIs
- Should not break current working projects
- Must preserve lock file as single source of truth
- Should work with both editable and non-editable environments
- Must handle both wheel and sdist source preferences
- Should not require users to manually list transitive dependencies

### Prior Art

- **ADR-003:** Python (uv2nix) Flake-Parts Module - established overlay composition
- **ADR-012:** Python Overlay Precedence Test - added regression test (but doesn't catch this issue)
- **PR #79:** Fixed build-systems overlay ordering (but didn't solve transitive deps)
- **Issue #78:** Original bug report and investigation

## Decision

**TBD** - This ADR explores solutions and will be updated with final decision after investigation and prototyping.

## Alternatives Considered

### Alternative A — Include ALL Locked Packages (Ideal)

**Description:** Modify our Python module to overlay ALL packages from `uv.lock`, not just direct dependencies.

**Approach:**
```nix
# Current (broken):
baseOverlay = workspace.mkPyprojectOverlay {
  sourcePreference = cfg.sourcePreference;
};

# Proposed:
allPackagesSpec = /* somehow get all packages from uv.lock */;
baseOverlay = workspace.mkPyprojectOverlay {
  sourcePreference = cfg.sourcePreference;
  spec = allPackagesSpec;  # ALL packages, not just direct deps
};
```

**Investigation Needed:**
1. Does uv2nix provide an API to get all locked packages?
   - Check `workspace` object attributes
   - Check if `workspace.deps` has other attributes besides `default`
   - Check if `uvLock` is accessible directly

2. Can we construct a spec that includes all packages?
   - Parse `uv.lock` ourselves?
   - Use `lock1.resolveDependencies` with all package names?
   - Create synthetic spec with all packages?

3. Does `mkPyprojectOverlay` support this use case?
   - Would passing all packages cause performance issues?
   - Would it cause dependency resolution conflicts?
   - Does it handle packages with no direct references?

**Pros:**
- ✅ Comprehensive: Solves the problem for all transitive deps
- ✅ Correct: Lock file becomes true single source of truth
- ✅ Automatic: No user intervention needed
- ✅ Future-proof: Works for any transitive dependency
- ✅ Aligns with user expectations: "My lock file should determine versions"

**Cons:**
- ❌ API uncertainty: uv2nix may not provide this capability
- ❌ Performance: Overlaying hundreds of packages might be slow
- ❌ Complexity: May require custom overlay construction
- ❌ Upstream dependency: Might need uv2nix changes

**Feasibility:** Unknown - requires investigation of uv2nix API

---

### Alternative B — Parse uv.lock and Create Custom Overlay

**Description:** Bypass `mkPyprojectOverlay` entirely and create our own overlay function that reads `uv.lock` directly.

**Approach:**
```nix
# In our Python module:
customBaseOverlay = final: prev:
  let
    uvLock = lib.importTOML "${cfg.workspaceRoot}/uv.lock";
    
    buildPackage = package: # Use uv2nix's build functions
      if isLocalProject package
      then uv2nix.lib.build.local { ... }
      else uv2nix.lib.build.remote { ... };
    
    allPackages = map (pkg: {
      name = pkg.name;
      value = buildPackage pkg;
    }) uvLock.package;
  in
    builtins.listToAttrs allPackages;
```

**Investigation Needed:**
1. Can we access uv2nix's build functions directly?
2. How does dependency resolution work without `resolveDependencies`?
3. Do we need to handle environment markers ourselves?
4. How do we handle local vs remote packages?

**Pros:**
- ✅ Full control: We decide exactly what gets overlaid
- ✅ Comprehensive: Can include all packages from lock
- ✅ No upstream dependency: Works with current uv2nix
- ✅ Flexible: Can add custom logic/filters

**Cons:**
- ❌ High complexity: Reimplementing overlay logic
- ❌ Maintenance burden: Must track uv2nix API changes
- ❌ Error-prone: Easy to miss edge cases
- ❌ Duplicate effort: uv2nix already solves this
- ❌ Environment markers: Complex to handle correctly
- ❌ Build function access: May not be part of stable API

**Feasibility:** Possible but high effort and maintenance

---

### Alternative C — Resolve All Transitive Dependencies into Spec

**Description:** Before calling `mkPyprojectOverlay`, resolve all transitive dependencies and add them to the spec.

**Approach:**
```nix
# Use uv2nix's dependency resolution to get ALL packages
allResolvedDeps = lock1.resolveDependencies {
  lock = uvLock;
  environ = defaultEnviron;
  dependencies = attrNames workspace.deps.default;
};

# Create spec that includes transitive deps
fullSpec = workspace.deps.default // (
  builtins.listToAttrs (map (name: {
    inherit name;
    value = { /* minimal spec */ };
  }) (attrNames allResolvedDeps))
);

# Now use this enhanced spec
baseOverlay = workspace.mkPyprojectOverlay {
  sourcePreference = cfg.sourcePreference;
  spec = fullSpec;
};
```

**Investigation Needed:**
1. Does `resolveDependencies` transitively resolve all deps?
2. What attributes does spec need for each package?
3. Can we create synthetic specs for transitive deps?
4. Will this cause conflicts with `filterConflicts`?

**Pros:**
- ✅ Uses existing APIs: Leverages uv2nix's resolution
- ✅ Comprehensive: Includes all transitive deps
- ✅ Moderate complexity: Some custom logic but uses uv2nix
- ✅ Compatible: Works within current architecture

**Cons:**
- ❌ API uncertainty: Spec format requirements unclear
- ❌ Resolution logic: May need to call resolveDependencies outside overlay
- ❌ Chicken-and-egg: resolveDependencies happens inside mkPyprojectOverlay
- ❌ Potential inefficiency: Resolving dependencies twice?

**Feasibility:** Unknown - depends on API details

---

### Alternative D — Manual Transitive Dependency Override

**Description:** Provide a module option for users to explicitly list problematic transitive dependencies that need version overrides.

**Approach:**
```nix
# Module option:
jackpkgs.python.transitiveOverrides = {
  typing-extensions = "4.15.0";
  setuptools = "75.0.0";
};

# In module:
transitiveOverlay = final: prev: 
  lib.mapAttrs (name: version:
    prev.${name}.overridePythonAttrs (old: {
      inherit version;
      src = fetchPypi { inherit name version; };
    })
  ) cfg.transitiveOverrides;

overlayList = [
  buildSystemsOverlay
  baseOverlay
  transitiveOverlay  # Apply user's transitive overrides
  ensureSetuptools
  cfg.extraOverlays
];
```

**Pros:**
- ✅ Simple implementation: Just another overlay
- ✅ No upstream dependency: Works with current uv2nix
- ✅ Targeted: Only override what's needed
- ✅ Explicit: User knows what's being overridden

**Cons:**
- ❌ Manual maintenance: User must identify conflicts
- ❌ Doesn't scale: Each project needs configuration
- ❌ Defeats lock files: User specifies versions outside lock
- ❌ Discovery burden: User must diagnose version issues
- ❌ Incomplete: Only fixes known issues

**Feasibility:** High - easy to implement

**Use case:** Stopgap workaround until proper solution available

---

### Alternative E — Extract Transitive Deps from uv.lock Directly

**Description:** Parse `uv.lock` to get all package names, then call `mkPyprojectOverlay` with a spec containing all of them.

**Approach:**
```nix
# Read uv.lock
uvLock = lib.importTOML "${cfg.workspaceRoot}/uv.lock";

# Extract all package names
allPackageNames = map (pkg: pkg.name) uvLock.package;

# Create minimal spec entries for each
allPackagesSpec = builtins.listToAttrs (map (name: {
  inherit name;
  value = { 
    # Minimal spec - might just need name?
    # Or reference from workspace.deps if exists?
  };
}) allPackageNames);

# Merge with direct deps (direct deps take precedence for spec attrs)
fullSpec = allPackagesSpec // workspace.deps.default;

# Use enhanced spec
baseOverlay = workspace.mkPyprojectOverlay {
  sourcePreference = cfg.sourcePreference;
  spec = fullSpec;
};
```

**Investigation Needed:**
1. What's the minimal valid spec entry format?
2. Will `mkPyprojectOverlay` accept packages with minimal specs?
3. How does this interact with `filterConflicts`?
4. Do we need to handle environment markers?

**Pros:**
- ✅ Direct approach: Uses data from lock file
- ✅ Comprehensive: Covers all packages in lock
- ✅ Moderate complexity: Some parsing but uses uv2nix APIs
- ✅ No dependency resolution: Just uses what's in lock

**Cons:**
- ❌ Spec format uncertainty: Need to know minimal requirements
- ❌ Lock file parsing: Direct dependency on uv.lock format
- ❌ Environment markers: May need to filter based on platform
- ❌ Error handling: What if spec is invalid?

**Feasibility:** Moderate - depends on spec requirements

---

### Alternative F — Upstream Enhancement to uv2nix

**Description:** Request or contribute a feature to uv2nix that provides an "all packages" overlay mode.

**Approach:**
```nix
# Proposed API addition to uv2nix:
workspace.mkAllPackagesOverlay {
  sourcePreference = cfg.sourcePreference;
  # No spec parameter - overlays everything in uv.lock
}

# Or:
workspace.mkPyprojectOverlay {
  sourcePreference = cfg.sourcePreference;
  includeTransitive = true;  # New option
}
```

**Investigation Needed:**
1. Is this use case in scope for uv2nix?
2. Would maintainers accept a PR?
3. What's the right API design?
4. Timeline for acceptance and release?

**Pros:**
- ✅ Proper solution: Fixes root cause
- ✅ Benefits ecosystem: Other users need this too
- ✅ Maintained upstream: Not our technical debt
- ✅ Best practice: Uses official API

**Cons:**
- ❌ Timeline: Could take weeks/months
- ❌ Acceptance risk: Maintainers might reject
- ❌ Design complexity: Need to handle various use cases
- ❌ Waiting: Can't fix issue immediately

**Feasibility:** High - but long timeline

**Approach:** Use as long-term solution alongside short-term workaround

---

## Investigation Plan

### Phase 1: API Discovery (2-3 hours)

**Goal:** Understand what uv2nix provides for accessing all locked packages.

**Tasks:**

1. **Examine workspace object structure:**
   ```bash
   nix eval --impure --expr '
     let
       flake = builtins.getFlake (toString ./.);
       workspace = ...;
     in
       builtins.attrNames workspace
   '
   ```

2. **Check for alternative deps attributes:**
   - Is there `workspace.deps.all`?
   - Is there `workspace.allPackages`?
   - Can we access `workspace.lock` directly?

3. **Read uv2nix source code:**
   - `lib/workspace.nix` - workspace loading
   - `lib/overlays.nix` - overlay creation
   - `lib/lock.nix` - lock file parsing
   - Look for APIs to access all packages

4. **Experiment with spec formats:**
   - What happens if we pass empty spec? `{}`
   - What happens if we pass just `{ package-name = {}; }`?
   - What attributes are required in spec entries?

5. **Test Alternative E approach:**
   - Parse uv.lock
   - Create synthetic specs
   - See if mkPyprojectOverlay accepts them

**Success Criteria:**
- Understand what APIs are available
- Know if Alternative A or E is feasible
- Have working proof-of-concept for at least one approach

**Kill Condition:** If no API available and custom parsing too complex (>4 hours), pivot to Alternative D (manual overrides) as immediate workaround and pursue Alternative F (upstream) as proper fix.

---

### Phase 2: Prototype Solution (3-4 hours)

**Goal:** Implement working solution based on Phase 1 findings.

**Tasks:**

1. **Implement chosen approach** (based on Phase 1 results):
   - Alternative A if API exists
   - Alternative E if spec format is simple
   - Alternative C if resolution works outside overlay
   - Alternative D if no other option works

2. **Test with affected user project:**
   - Apply changes to jackpkgs
   - Rebuild user's Python environment
   - Verify `typing-extensions` version is correct
   - Verify import succeeds

3. **Test with multiple environments:**
   - Editable vs non-editable
   - Wheel vs sdist sourcePreference
   - Multiple Python versions if applicable

4. **Measure performance impact:**
   - Time to evaluate overlays
   - Time to build environment
   - Number of packages in overlay

**Success Criteria:**
- Solution works for test case (typing-extensions)
- No regressions in existing projects
- Performance is acceptable (<10% slowdown)

---

### Phase 3: Integration & Testing (2-3 hours)

**Goal:** Integrate solution into Python module with proper testing.

**Tasks:**

1. **Update python.nix:**
   - Implement solution cleanly
   - Add comprehensive comments explaining approach
   - Update overlay composition documentation

2. **Update or create tests:**
   - Modify `tests/python-overlay-precedence-integration.nix` to test transitive deps
   - Or create new test specifically for transitive deps
   - Test should fail if transitive deps aren't overlaid

3. **Update documentation:**
   - Update ADR-003 if overlay composition changes
   - Document any new module options
   - Add troubleshooting guide if workarounds needed

4. **Test with real projects:**
   - Test with affected user project
   - Test with other projects using jackpkgs.python
   - Verify no regressions

**Success Criteria:**
- All tests pass
- Real projects work correctly
- Documentation is accurate

---

### Phase 4: Upstream Contribution (If applicable, 4-8 hours)

**Goal:** If custom solution was needed, contribute proper fix to uv2nix.

**Tasks:**

1. **Open issue in uv2nix:**
   - Describe use case and problem
   - Show evidence from our investigation
   - Propose API enhancement

2. **Wait for maintainer feedback:**
   - Discuss design options
   - Agree on API approach

3. **Implement PR (if accepted):**
   - Add `includeTransitive` option or similar
   - Add tests for new functionality
   - Update documentation

4. **Migrate jackpkgs to use upstream solution:**
   - Once released, update our dependency
   - Simplify our code to use official API
   - Remove custom workarounds

**Success Criteria:**
- Issue filed with clear problem statement
- Either PR accepted or clear alternative provided
- Long-term proper solution in place

---

## Implementation Phases

**Phase 1** (Required): API Discovery - determines which alternative is feasible  
**Phase 2** (Required): Implement chosen solution  
**Phase 3** (Required): Testing and integration  
**Phase 4** (Optional): Upstream contribution if needed

**Total Estimated Time:** 7-10 hours (excluding Phase 4)

**Owner:** TBD

**Dependencies:**
- Phase 2 depends on Phase 1 findings
- Phase 3 depends on Phase 2 implementation
- Phase 4 depends on Phase 3 validation

**Rollback Plan:**
- If solution doesn't work, revert and use Alternative D (manual overrides) as interim
- Document limitation in module documentation
- File issue for long-term fix

---

## Consequences

**TBD** - Will be updated after solution is chosen and implemented.

### Potential Benefits (Depending on Solution)

- Lock file becomes true single source of truth for all dependencies
- No more import errors from version mismatches
- Users don't need to diagnose or fix transitive dependency issues
- Consistent behavior across all Python packages
- Better alignment with uv/pip behavior

### Potential Trade-offs (Depending on Solution)

- Increased overlay evaluation time (if overlaying all packages)
- More complex module implementation (if custom parsing)
- Additional maintenance burden (if custom solution)
- Dependency on uv.lock format stability (if direct parsing)

### Potential Risks & Mitigations

- **Risk:** Performance degradation from overlaying many packages
  - **Mitigation:** Measure and optimize; consider lazy evaluation
  
- **Risk:** Solution breaks in future uv2nix versions
  - **Mitigation:** Pin uv2nix version; add integration tests; contribute upstream
  
- **Risk:** Edge cases not covered by solution
  - **Mitigation:** Comprehensive testing; provide escape hatch (extraOverlays)

---

## Related

- **Issue #78:** pyproject-build-systems overlays override user's uv.lock runtime dependencies
  - https://github.com/jmmaloney4/jackpkgs/issues/78
- **PR #79:** Fix Python overlay precedence (partial fix)
  - https://github.com/jmmaloney4/jackpkgs/pull/79
- **ADR-003:** Python (uv2nix) Flake-Parts Module
  - Documents overlay composition architecture
- **ADR-012:** Python Overlay Precedence Test
  - Integration test that should be updated to catch this issue
- **uv2nix lib/overlays.nix:** Source of the limitation
  - https://github.com/pyproject-nix/uv2nix/blob/main/lib/overlays.nix

---

## Questions for Discussion

1. **Scope:** Should we overlay ALL packages or provide filtering?
   - Pro (all): Complete solution, no edge cases
   - Pro (filtered): Better performance, less risk

2. **Performance:** What's acceptable overlay evaluation time?
   - Current: ~X seconds
   - With all packages: ~Y seconds (TBD)
   - Threshold: <N seconds? <M% increase?

3. **Upstream:** Should we wait for uv2nix enhancement or implement custom?
   - Pro (wait): Proper long-term solution
   - Pro (custom): Immediate fix, full control

4. **Workarounds:** Should we ship Alternative D (manual overrides) as interim?
   - Pro: Unblocks users immediately
   - Con: Technical debt, user burden

---

Author: TBD  
Date: 2025-10-25  
Status: Proposed - Awaiting Investigation & Decision  
Related: Issue #78, PR #79, ADR-003, ADR-012

