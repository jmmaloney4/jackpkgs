# ADR-012: uv2nix API Compliance Audit and Corrections

## Status

Proposed

## Context

The `jackpkgs.python` module (ADR-003) wraps uv2nix to provide opinionated Python environment management. While the initial implementation followed uv2nix patterns from examples and experimentation, a comprehensive audit against the official [uv2nix documentation](https://pyproject-nix.github.io/uv2nix/usage/getting-started.html) revealed several discrepancies between our implementation and the recommended patterns.

This ADR documents the findings of a thorough compliance audit and proposes corrections to align our module with uv2nix best practices. The goal is to ensure long-term maintainability, avoid subtle bugs, and provide users with behavior consistent with upstream recommendations.

## Audit Methodology

1. Retrieved and analyzed the official uv2nix "Getting Started" documentation
2. Performed line-by-line comparison of `modules/flake-parts/python.nix` against documented patterns
3. Categorized findings by severity (High/Medium/Low)
4. Identified both deviations from recommendations and undocumented extensions
5. Prepared refactoring recommendations with minimal disruption to existing users

## Audit Findings

### ✅ Correct Implementations

The following patterns are correctly implemented per documentation:

1. **Workspace Loading** (python.nix:222)
   ```nix
   workspace = uv2nix.lib.workspace.loadWorkspace {inherit workspaceRoot;}
   ```
   ✅ Exact match to documented API

2. **Python Base Construction** (python.nix:237-240)
   ```nix
   pythonBase = pkgs.callPackage pyproject-nix.build.packages {
     python = sysCfg.pythonPackage;
     stdenv = stdenvForPython;
   };
   ```
   ✅ Follows recommended pattern

3. **Overlay Generation** (python.nix:242-244)
   ```nix
   baseOverlay = workspace.mkPyprojectOverlay {
     sourcePreference = cfg.sourcePreference;
   };
   ```
   ✅ Correct usage of `mkPyprojectOverlay` with sourcePreference

4. **Package Set Composition** (python.nix:267)
   ```nix
   pythonSet = pythonBase.overrideScope (lib.composeManyExtensions overlayList);
   ```
   ✅ Uses `overrideScope` with `composeManyExtensions` as documented

5. **Virtual Environment Creation** (python.nix:290, 326)
   ```nix
   pythonSet.mkVirtualEnv name spec
   ```
   ✅ Matches documented `mkVirtualEnv` API

6. **Editable Overlay** (python.nix:324)
   ```nix
   editableSet = pythonSet.overrideScope (workspace.mkEditablePyprojectOverlay overlayArgs);
   ```
   ✅ Proper separate package set for editable installs

### ⚠️ Issues and Discrepancies

#### Issue 1: Missing PYTHONPATH Unset (HIGH PRIORITY)

**Location:** python.nix:379-390

**Current Implementation:**
```nix
shellHook = ''
  repo_root="$(${lib.getExe config.flake-root.package})"
  export REPO_ROOT="$repo_root"

  ${lib.optionalString (editableEnv != null) ''
    export UV_NO_SYNC="1"
    export UV_PYTHON="${lib.getExe editableEnv}"
    export UV_PYTHON_DOWNLOADS="false"
    export PATH="${editableEnv}/bin:$PATH"
  ''}
'';
```

**Documentation Requirement:**
> "Unset `PYTHONPATH` to eliminate unintended side effects from Nix builders."

**Issue:** The shell hook does not unset `PYTHONPATH`, which can cause Python to incorrectly import packages from the Nix build environment instead of the virtual environment.

**Impact:**
- Potential for subtle import errors
- Packages may be found from unexpected locations
- Non-deterministic behavior depending on shell environment state

**Severity:** **HIGH** - Can cause hard-to-debug import issues

#### Issue 2: Incorrect UV_PYTHON_DOWNLOADS Value (MEDIUM PRIORITY)

**Location:** python.nix:386

**Current Implementation:**
```nix
export UV_PYTHON_DOWNLOADS="false"
```

**Documentation Requirement:**
```nix
UV_PYTHON_DOWNLOADS = "never"
```

**Issue:** Documentation specifies the string value `"never"`, not `"false"`.

**Impact:**
- While both may work, this deviates from documented behavior
- Potential for breakage if uv changes parsing logic
- Confusing for users reading both our code and upstream docs

**Severity:** **MEDIUM** - Functional but non-standard

#### Issue 3: Build System Overlay Inclusion (HIGH PRIORITY - CONFIRMED INCORRECT)

**Location:** python.nix:258-265

**Current Implementation:**
```nix
overlayList =
  [baseOverlay]
  ++ [
    jackpkgsInputs.pyproject-build-systems.overlays.wheel
    jackpkgsInputs.pyproject-build-systems.overlays.sdist
  ]
  ++ [ensureSetuptools]
  ++ cfg.extraOverlays;
```

**Documented Pattern:**
```nix
pythonSet = pythonBase.overrideScope (
  lib.composeManyExtensions [
    pyproject-build-systems.overlays.wheel  # Only ONE overlay
    overlay
  ]
);
```

**Issue:** We unconditionally include BOTH `overlays.wheel` AND `overlays.sdist` regardless of the `sourcePreference` setting. After extensive documentation research, this is **definitively incorrect**.

**Evidence from Documentation:**
1. The getting started guide shows using ONLY `overlays.wheel`
2. GitHub issue examples show using ONLY `overlays.default`
3. Documentation states: "The build system overlay has the same sdist/wheel distinction as mkPyprojectOverlay"
4. Build-system-pkgs provides THREE overlays:
   - `overlays.default` - general purpose build tools
   - `overlays.wheel` - prefer build systems from binary wheels
   - `overlays.sdist` - prefer build systems from source
5. Documentation explicitly states: "The choice between `wheel` and `sdist` should align with your `sourcePreference` setting"

**Why This is Wrong:**
- Including both overlays violates the documented pattern
- The overlays are meant to be mutually exclusive choices, not complementary
- This could cause unpredictable behavior when both overlays define the same packages
- Wastes resources by including unnecessary overlay layers

**Correct Pattern:**
Only ONE build system overlay should be included, matching the `sourcePreference`:
- If `sourcePreference = "wheel"` → use `overlays.wheel`
- If `sourcePreference = "sdist"` → use `overlays.sdist`
- Alternative: use `overlays.default` for general purpose

**Impact:**
- Incorrect overlay composition
- Potential for package version conflicts
- Deviation from all documented examples
- May cause subtle build failures or unexpected behavior

**Severity:** **HIGH** - Clear deviation from documented pattern that could cause issues

#### Issue 4: defaultSpec Fallback Design (LOW PRIORITY)

**Location:** python.nix:269, 296-299, 312-315

**Current Implementation:**
```nix
defaultSpec = workspace.deps.default;

mkEnv = { name, spec ? null }: let
  finalSpec = if spec == null then defaultSpec else spec;
in mkEnvForSpec { inherit name; spec = finalSpec; };
```

**Documentation Pattern:**
```nix
# Documented approach 1: Using dependency presets
pythonSet.mkVirtualEnv "env-name" workspace.deps.default

# Documented approach 2: Explicit specification
pythonSet.mkVirtualEnv "env-name" { package-name = []; }
```

**Issue:** The documentation shows direct usage of `workspace.deps.default` at call sites, not extraction into a `defaultSpec` variable with fallback logic. Additionally, ADR-006 removed the `extras` convenience option and forces explicit `spec` configuration, making the null fallback potentially dead code.

**Current behavior:**
- `spec` is optional in environment definitions
- Falls back to `workspace.deps.default` if unspecified
- Examples in ADR-003 show `spec = pythonWorkspace.defaultSpec;` (explicit)
- Examples in python.nix:112 show `spec = {}; # workspace.deps.default // ...` (commented)

**Inconsistencies:**
1. If ADR-006 requires explicit specs, why allow `spec ? null`?
2. The example comment suggests `spec = {}` but actual default is `workspace.deps.default`
3. No clear guidance on when the fallback is appropriate

**Impact:**
- Confusing API surface (is spec required or optional?)
- Potentially unused code path (if all real usage requires explicit spec)
- Documentation mismatch between ADR examples and implementation

**Severity:** **LOW** - Functional but potentially confusing API design

#### Issue 5: Missing Advanced Configuration Options (LOW PRIORITY)

**Locations:** python.nix:220-223 (loadWorkspace), python.nix:242-244 (mkPyprojectOverlay)

**Available but Unexposed APIs:**

According to the uv2nix API reference, several advanced configuration options are available but not exposed by our module:

1. **`loadWorkspace` config parameter:**
   ```nix
   workspace = uv2nix.lib.workspace.loadWorkspace {
     workspaceRoot = ./.;
     config = { /* optional configuration overrides */ };
   };
   ```
   Supported config keys:
   - `tool.uv.no-binary`
   - `tool.uv.no-build`
   - `tool.uv.no-binary-package`
   - `tool.uv.no-build-package`

2. **`mkPyprojectOverlay` environ parameter:**
   ```nix
   overlay = workspace.mkPyprojectOverlay {
     sourcePreference = "wheel";
     environ = {
       platform_release = "5.10.65";  # Override for marker evaluation
     };
   };
   ```
   Used to customize PEP 508 environment marker evaluation (e.g., Linux kernel version, macOS version).

**Current Implementation:**
Our module doesn't expose these configuration options, passing only the minimal required parameters.

**Impact:**
- Advanced users cannot customize uv configuration overrides
- Cannot override platform metadata for marker evaluation
- Must fork/modify the module for these use cases

**Recommendation:**
Consider adding these as advanced options in a future iteration, but LOW priority since:
- Most users won't need them
- They can be worked around via `extraOverlays` if needed
- Config can be set in pyproject.toml directly for most cases

**Severity:** **LOW** - Missing advanced features that most users don't need

#### Issue 6: workspace.deps Usage Documentation

**Status:** ✅ CORRECTLY IMPLEMENTED

**Finding:** During research, confirmed that `workspace.deps` provides four pre-configured dependency sets:
- `workspace.deps.default` - No optional-dependencies or dependency-groups enabled (production)
- `workspace.deps.optionals` - All optional-dependencies enabled
- `workspace.deps.groups` - All dependency-groups enabled
- `workspace.deps.all` - All optional-dependencies & dependency-groups enabled

**Current Usage:** python.nix:269
```nix
defaultSpec = workspace.deps.default;
```

**Assessment:** Our usage of `workspace.deps.default` is correct per documentation. This is the recommended starting point for dependency specifications.

**Note:** While we correctly use this API, our abstraction into `defaultSpec` and exposure via `pythonWorkspace.defaultSpec` provides a clean interface for users to reference in their environment configurations.

### 📋 Undocumented Extensions (Not Issues)

The following are valuable additions beyond the documented minimal pattern:

#### Extension 1: Darwin SDK Version Handling

**Location:** python.nix:225-235

**Implementation:**
```nix
stdenvForPython =
  if pkgs.stdenv.isDarwin
  then
    pkgs.stdenv.override {
      targetPlatform =
        pkgs.stdenv.targetPlatform
        // {
          darwinSdkVersion = cfg.darwin.sdkVersion;
        };
    }
  else pkgs.stdenv;
```

**Analysis:** Not mentioned in uv2nix documentation. This addresses real-world macOS compatibility issues and is a valuable practical extension.

**Assessment:** ✅ Keep - pragmatic addition for macOS support

#### Extension 2: Setuptools Override Overlay

**Location:** python.nix:246-256

**Implementation:**
```nix
ensureSetuptools = final: prev: let
  add = name:
    if builtins.hasAttr name prev
    then
      lib.nameValuePair name (prev.${name}.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [final.setuptools];
      }))
    else null;
  pairs = builtins.filter (x: x != null) (map add cfg.setuptools.packages);
in
  builtins.listToAttrs pairs;
```

**Analysis:** Documentation mentions sdist builds "require more manual overrides" but doesn't show this pattern. This fixes packages with incorrect/missing setuptools declarations.

**Assessment:** ✅ Keep - pragmatic workaround for upstream packaging issues

**Consideration:** The hardcoded list `["peewee" "multitasking" "sgmllib3k"]` represents known broken packages. Consider making this more discoverable/documentable.

#### Extension 3: Virtual Environment Post-Processing

**Location:** python.nix:271-284

**Implementation:**
```nix
addMainProgram = drv:
  drv.overrideAttrs (old: {
    meta = (old.meta or {}) // {mainProgram = "python";};
    postFixup =
      (lib.optionalString (old ? postFixup) old.postFixup)
      + ''
        if [ -f "$out/bin/Activate.ps1" ]; then
          rm -f "$out/bin/Activate.ps1"
        fi
        if [ -d "$out/bin" ]; then
          chmod +x "$out/bin"/activate* 2>/dev/null || true
        fi
      '';
  });
```

**Analysis:** Not documented. Adds:
- `mainProgram` metadata for better `nix run` UX
- PowerShell activation script removal
- Activation script executable permissions

**Assessment:** ✅ Keep - valuable UX improvements

**Consideration:** The PowerShell script removal and chmod fixes suggest possible upstream issues that should be reported to pyproject-nix or uv2nix maintainers.

## Decisions

### 1. Fix High-Priority Issues Immediately

**Decision:** Fix the missing `PYTHONPATH` unset and incorrect `UV_PYTHON_DOWNLOADS` value.

**Rationale:** These are clear deviations from documented best practices that could cause subtle bugs.

**Changes:**
```nix
shellHook = ''
  repo_root="$(${lib.getExe config.flake-root.package})"
  export REPO_ROOT="$repo_root"
  unset PYTHONPATH  # FIX: Prevent Nix builder pollution

  ${lib.optionalString (editableEnv != null) ''
    export UV_NO_SYNC="1"
    export UV_PYTHON="${lib.getExe editableEnv}"
    export UV_PYTHON_DOWNLOADS="never"  # FIX: Use documented value
    export PATH="${editableEnv}/bin:$PATH"
  ''}
'';
```

### 2. Fix Build System Overlay Usage (INVESTIGATION COMPLETE)

**Decision:** Include ONLY the build system overlay matching `sourcePreference`, not both.

**Rationale:** After extensive research of uv2nix documentation, examples, and API references:
1. All documented examples show using ONLY ONE overlay
2. The pyproject-build-systems documentation states the overlays have a "sdist/wheel distinction"
3. Documentation explicitly states: "The choice between `wheel` and `sdist` should align with your `sourcePreference` setting"
4. Including both overlays violates the documented pattern and could cause conflicts

**Research Completed:**
- ✅ Searched additional uv2nix documentation pages (lib/workspace.html, patterns/overriding-build-systems.html, platform-quirks.html)
- ✅ Reviewed getting started guide and hello-world examples
- ✅ Checked pyproject-build-systems documentation
- ✅ Examined GitHub issues and real-world usage patterns

**Changes:**
```nix
overlayList =
  [baseOverlay]
  ++ (if cfg.sourcePreference == "wheel"
      then [jackpkgsInputs.pyproject-build-systems.overlays.wheel]
      else [jackpkgsInputs.pyproject-build-systems.overlays.sdist])
  ++ [ensureSetuptools]
  ++ cfg.extraOverlays;
```

**Alternative Consideration:** We could also use `overlays.default` as a source-agnostic option, but matching sourcePreference is more explicit and aligns better with the documented pattern.

### 3. Clarify spec Parameter Design

**Decision:** Make `spec` a required parameter and update documentation.

**Rationale:**
- Aligns with ADR-006's decision to require explicit configuration
- Eliminates confusion about when defaultSpec is used
- Forces users to be explicit about dependencies
- Removes potentially dead code

**Changes:**
```nix
mkEnv = {
  name,
  spec,  # Remove ? null - make it required
}:
  mkEnvForSpec { inherit name spec; };

mkEditableEnv = {
  name,
  spec,  # Remove ? null - make it required
  members ? null,
  root ? null,
}:
  # ... implementation
```

**Breaking Change:** Yes - environments without explicit `spec` will fail.

**Migration Path:**
```nix
# OLD (would break):
environments.default = {
  name = "python-env";
  # spec implicitly workspace.deps.default
};

# NEW (required):
environments.default = {
  name = "python-env";
  spec = pythonWorkspace.defaultSpec;  # or workspace.deps.default
};
```

**Documentation Updates Required:**
- Update ADR-003 quick start examples
- Update python.nix option description
- Add migration notes for existing users

### 4. Preserve Undocumented Extensions

**Decision:** Keep all undocumented extensions (Darwin SDK, setuptools overlay, venv post-processing).

**Rationale:** These are valuable pragmatic additions that solve real problems not addressed by the minimal uv2nix documentation.

**Documentation:** Add comments in the code explaining why these extensions exist and their purpose.

## Implementation Plan

### Phase 1: Immediate Fixes (COMPLETED ✅)
- ✅ Document all audit findings
- ✅ Fix PYTHONPATH unset
- ✅ Fix UV_PYTHON_DOWNLOADS value
- ✅ Fix build system overlay selection
- ✅ Add code comments for undocumented extensions

### Phase 2: Research (COMPLETED ✅)
- ✅ Investigate build system overlay usage patterns
- ✅ Review additional uv2nix documentation (lib/workspace.html, patterns/overriding-build-systems.html, platform-quirks.html)
- ✅ Examined real-world examples and GitHub issues
- ✅ Document findings in this ADR (updated)

**Key Findings:**
- Build system overlays should match sourcePreference (wheel OR sdist, not both)
- Confirmed workspace.deps API usage is correct
- Identified missing advanced config options (environ, loadWorkspace config)
- Verified editable overlay usage is correct

### Phase 3: Breaking Changes (Future ADR or Update)
- [ ] Make `spec` required parameter
- [ ] Update all examples and documentation
- [ ] Provide migration guide
- [ ] Version bump / changelog entry

### Phase 4: Upstream Contributions (Optional)
- [ ] Report PowerShell script in venv output to pyproject-nix
- [ ] Report activation script permissions issue
- [ ] Contribute documentation clarifications to uv2nix

## Testing and Validation

### Validation Checklist

- [ ] Verify `PYTHONPATH` is unset in devshell
- [ ] Verify `UV_PYTHON_DOWNLOADS="never"` is set
- [ ] Test on macOS and Linux
- [ ] Verify no import errors from Nix build environment
- [ ] Test with existing zeus project (regression test)
- [ ] Test with workspace-only project
- [ ] Test with both wheel and sdist sourcePreference

### Test Cases to Add

1. **Environment Variable Test**
   ```bash
   nix develop --command bash -c 'env | grep -E "PYTHONPATH|UV_"'
   # Should show UV_* but NOT PYTHONPATH
   ```

2. **Import Isolation Test**
   ```bash
   nix develop --command python -c "import sys; print('\n'.join(sys.path))"
   # Should only show venv paths, not Nix store paths from builders
   ```

## Consequences

### Positive
- Compliance with documented uv2nix best practices
- Reduced risk of subtle environment pollution bugs
- Clearer API surface (required vs optional parameters)
- Better maintainability as uv2nix evolves
- Foundation for future contributions to upstream documentation

### Negative
- Breaking change for users who rely on implicit `defaultSpec` fallback (Decision #3)
- Build system overlay change might affect package builds (though should be more correct)
- Migration burden for existing projects

### Neutral
- Code complexity remains similar
- No performance impact expected
- Existing tests may need updates

## Open Questions

1. **Build System Overlays:** Should both wheel and sdist overlays be included, or only one based on sourcePreference?
   - **Status:** ✅ RESOLVED - Use only one overlay matching sourcePreference
   - **Decision:** See Decision #2 above
   - **Implementation:** Conditional inclusion based on cfg.sourcePreference

2. **Setuptools Package List:** Should the hardcoded setuptools package list be configurable or remain fixed?
   - **Status:** Deferred - working as-is
   - **Consider:** Future ADR if more packages are discovered

3. **Upstream Issues:** Should we report the PowerShell script and permissions issues?
   - **Status:** Yes, but deferred to Phase 4
   - **Action:** Create tracking issues after confirming reproducibility

## Related ADRs

- ADR-003: Python (uv2nix) Flake-Parts Module (original implementation)
- ADR-005: uv2nix Editable vs Non-Editable Envs (editable environment design)
- ADR-006: Workspace-Only Python Projects (removal of extras option)

## References

### Primary Documentation
- [uv2nix Getting Started Documentation](https://pyproject-nix.github.io/uv2nix/usage/getting-started.html)
- [uv2nix workspace API Reference](https://pyproject-nix.github.io/uv2nix/lib/workspace.html)
- [uv2nix Platform Quirks](https://pyproject-nix.github.io/uv2nix/platform-quirks.html)
- [uv2nix Overriding Build Systems](https://pyproject-nix.github.io/uv2nix/patterns/overriding-build-systems.html)
- [pyproject-nix Documentation](https://pyproject-nix.github.io/pyproject.nix/)
- [pyproject-build-systems Repository](https://github.com/pyproject-nix/build-system-pkgs)

### Implementation
- Current implementation: `modules/flake-parts/python.nix`

### Research Sources
- uv2nix GitHub issues and discussions
- Real-world examples in the uv2nix repository
- Verified examples from Medium article: "Nix Nirvana: Packaging Python Apps with uv2nix"

---

## Executive Summary

This comprehensive audit of the `jackpkgs.python` module's uv2nix usage identified **6 issues** ranging from HIGH to LOW priority:

### Critical Findings Requiring Immediate Action:
1. **HIGH:** Missing `PYTHONPATH` unset in shell hook → Can cause import pollution
2. **HIGH:** Incorrect build system overlay inclusion (both wheel AND sdist) → Should match sourcePreference
3. **MEDIUM:** Wrong `UV_PYTHON_DOWNLOADS` value ("false" should be "never")

### Design Questions for Future Consideration:
4. **LOW:** defaultSpec fallback design inconsistent with ADR-006's explicit spec requirement
5. **LOW:** Advanced uv2nix config options not exposed (environ, loadWorkspace config)
6. **NOTE:** workspace.deps.default usage is CORRECT ✅

### Validated Correct Implementations:
- ✅ Workspace loading API
- ✅ Python base construction
- ✅ Overlay generation
- ✅ Package set composition
- ✅ Virtual environment creation
- ✅ Editable overlay pattern
- ✅ workspace.deps usage

### Undocumented but Valuable Extensions:
- Darwin SDK version handling (macOS compatibility)
- Setuptools override overlay (fixes broken packages)
- Virtual environment post-processing (UX improvements)

**Recommendation:** Implement the 3 critical fixes immediately. These are straightforward changes that align with documented best practices and reduce risk of subtle bugs. The design questions can be addressed in future iterations.
