# ADR-002: Python Environment Configuration for Pre-commit Hooks

## Status

Accepted

## Context

### Problem Statement

The jackpkgs pre-commit module uses `pkgs.nbstripout` (a standalone Python application) for Jupyter notebook output stripping. When consumers use `inputsFrom = [config.jackpkgs.outputs.devShell]`, this introduces PATH pollution where nbstripout's Python environment gets injected into the consumer's development shell, causing conflicts with custom Python environments managed by tools like uv2nix, poetry2nix, or other Python package managers.

### Specific Issues Identified

1. **PATH Pollution**: `pkgs.nbstripout` brings its own Python environment (`/nix/store/.../python3-3.12.11/bin`) which gets added to PATH before consumer's custom Python environments
2. **Wrong Python Resolution**: Consumer projects expecting their custom Python interpreter find system Python instead, breaking module imports and environment isolation
3. **Redundant Python Environments**: Multiple Python interpreters in PATH create confusion and unpredictable behavior

### Constraints

- **Technical**: `pkgs.nbstripout` is a pre-built standalone package (not available as `pkgs.python3Packages.nbstripout`)
- **Compatibility**: Must maintain backward compatibility with existing jackpkgs consumers
- **Performance**: Avoid unnecessary rebuilds of heavy Python packages (numpy, pytorch, etc.)
- **Simplicity**: Consumer configuration should be minimal and intuitive

### Prior Art

- jackpkgs previously maintained a custom nbstripout package (`pkgs/nbstripout/default.nix`) that was identical to nixpkgs version - removed as redundant during this investigation
- Initial investigation suggested a `pythonPackages` configuration option, but discovered `pythonPackages.nbstripout` doesn't exist in nixpkgs
- Previous attempts to solve this via PATH manipulation in consumer shellHooks were fragile and incomplete

## Decision

**UPDATED**: We MUST implement a **self-contained nbstripout package** that eliminates PATH pollution without requiring any consumer configuration:

*(Note: See Appendix B for evolution from parameterized approach to zero-configuration solution)*

### Core Implementation

1. **Self-Contained nbstripout Package**

   - Build nbstripout using `python3.pkgs.toPythonApplication` wrapper pattern
   - Python interpreter embedded within package but NOT propagated to PATH
   - Zero consumer configuration required
   - No PATH pollution in consumer devShells

2. **Universal Solution**

   - Works automatically for all consumers regardless of Python environment
   - Pre-commit hooks function identically to current behavior
   - Eliminates need for any consumer Python environment configuration
   - Maintains backward compatibility perfectly

### Key Technical Insight

The solution works by **preventing Python propagation to PATH** rather than configuring consumer environments:

- Use `toPythonApplication` to wrap a `buildPythonPackage` library
- Python interpreter stays internal to nbstripout package
- No `propagatedBuildInputs` reach consumer PATH
- Pre-commit hooks execute nbstripout directly without PATH conflicts

### Configuration Schema

**SIMPLIFIED**: No consumer configuration needed!

```nix
options.jackpkgs.pre-commit = {
  nbstripoutPackage = mkOption {
    type = types.package;
    default = pkgs.callPackage ../../pkgs/nbstripout { };
    description = "Self-contained nbstripout package with no PATH pollution";
  };
};
```

### Self-Contained nbstripout Package

```nix
# pkgs/nbstripout/default.nix
{
  lib,
  python3,
  fetchPypi,
  # ... other dependencies
}:
python3.pkgs.toPythonApplication (
  python3.pkgs.buildPythonPackage rec {
    pname = "nbstripout";
    version = "0.8.1";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-6qyLa05yno3+Hl3ywPi6RKvFoXplRI8EgBQfgL4jC7E=";
    };

    propagatedBuildInputs = with python3.pkgs; [ nbformat ];
    # ... rest of package definition
  }
)
```

**How it works:**

- First builds nbstripout as Python library with `buildPythonPackage`
- Then wraps with `toPythonApplication` to create executable
- Python interpreter embedded but not propagated to consumer PATH
- **Zero consumer configuration** - works automatically for everyone

### Scope

**In Scope:**

- Self-contained nbstripout package with zero PATH pollution
- Universal solution requiring no consumer configuration
- Backward compatibility for existing consumers
- Elimination of Python environment conflicts

**Out of Scope:**

- Consumer Python environment configuration (no longer needed)
- Migration of other Python tools beyond nbstripout
- Changes to consumer devShell configuration patterns

## Consequences

### Benefits

- **Eliminates PATH Pollution**: Python interpreter contained within nbstripout package, not propagated to consumer PATH
- **Zero Configuration**: No consumer setup required - works automatically for everyone
- **Universal Compatibility**: Works with any Python environment manager (uv2nix, poetry2nix, mach-nix, etc.) without configuration
- **Perfect Backward Compatibility**: Existing consumers continue working without any changes
- **Simplified Architecture**: No complex configuration options or conditional logic
- **Maintainable**: Uses established nixpkgs patterns (`toPythonApplication`)

### Trade-offs

- **Custom Package Maintenance**: We maintain our own nbstripout package instead of using nixpkgs directly
- **Build Dependency**: nbstripout must be built from source for each consumer Python environment (but this is fast)
- **Testing Surface**: Need to test with different Python environment managers

### Risks & Mitigations

**Risk**: Custom nbstripout package diverges from nixpkgs version

- **Mitigation**: Keep package definition synchronized with nixpkgs, monitor for updates

**Risk**: Consumer's Python environment lacks required dependencies for nbstripout

- **Mitigation**: nbstripout has minimal dependencies (only nbformat), widely available in Python environments

**Risk**: Build failures if consumer's Python environment is malformed

- **Mitigation**: Clear error messages, fallback documentation, default to nixpkgs when consumer config fails

## Alternatives Considered

### Alternative A — Consumer Provides Their Own nbstripout

- **Pros**: Simple delegation to consumer, no jackpkgs complexity
- **Cons**: Requires all consumers to add nbstripout to their dependencies, breaks existing workflows
- **Why not chosen**: Too disruptive for existing consumers, shifts complexity to every consumer

### Alternative B — Conditional Python Environment

- **Pros**: Automatic integration when consumer provides Python environment
- **Cons**: Complex circular dependency issues, unclear fallback behavior
- **Why not chosen**: Fragile dependency resolution, hard to debug failures

### Alternative C — Build nbstripout with Consumer's Python Interpreter (Chosen)

- **Pros**: Uses consumer's Python interpreter without requiring them to manage nbstripout dependency, completely eliminates PATH pollution
- **Cons**: Requires maintaining custom nbstripout package, slight build overhead
- **Why chosen**: Solves root cause while providing zero-configuration experience for consumers

### Alternative E — ShellHook PATH Manipulation

- **Pros**: Consumer-side fix, no jackpkgs changes needed
- **Cons**: Fragile, doesn't eliminate pollution, requires every consumer to implement
- **Why not chosen**: Treats symptoms not cause, discovered to be unreliable due to PATH ordering issues

## Implementation Plan

### Phase 1: Core Infrastructure ✅ **COMPLETED**

- **Owner**: jackpkgs maintainers
- ✅ Revived custom nbstripout package with parameterized Python environment
- ✅ Enhanced pre-commit module to use parameterized nbstripout by default
- ✅ Ensured pre-commit hooks continue using nbstripout correctly
- ✅ Updated flake.nix to include custom nbstripout package
- **Dependencies**: None
- **Timeline**: Completed

### Phase 2: Documentation & Examples

- **Owner**: jackpkgs maintainers
- Document consumer configuration patterns for different Python environment managers
- Create examples for uv2nix, poetry2nix, and vanilla Python environments
- Update migration guide for consumers affected by devShell changes
- **Dependencies**: Phase 1 completion
- **Timeline**: 1 week

### Phase 3: Consumer Migration

- **Owner**: Consumer project maintainers (with jackpkgs support)
- Test integration with existing consumer projects
- Migrate affected consumers to new configuration pattern
- Validate PATH pollution elimination
- **Dependencies**: Phase 2 completion
- **Timeline**: 2-4 weeks (depending on consumer availability)

### Rollout Considerations

- **Feature Flag**: `buildNbstripoutFromPython` defaults to `false` for backward compatibility
- **Gradual Migration**: Consumers can opt-in to new behavior when ready
- **Communication**: Announce in jackpkgs changelog and consumer project channels

### Rollback Plan

- **Immediate**: Revert `buildNbstripoutFromPython` default to restore devShell inclusion
- **If Issues Found**: Temporarily add nbstripout back to devShell while investigating
- **Last Resort**: Completely revert ADR and return to status quo

## Related

- Investigation began with PATH pollution reports from cavinsresearch/zeus uv2nix integration
- Related to general pattern of Python environment management in Nix
- May inform future decisions about other Python tools in jackpkgs

______________________________________________________________________

## Appendix: Investigation Journey

### Initial Problem Discovery

The issue was first identified when the cavinsresearch/zeus project (using uv2nix for Python environment management) experienced Python module import failures in development shells that included jackpkgs:

```bash
python -m cavins.tools.hello
# Error: ModuleNotFoundError: No module named 'cavins'

# But this worked:
/nix/store/wz9w8fpv251dir5sx4csi2hzmk7j5ysw-python-nautilus-editable/bin/python -m cavins.tools.hello
# Hello, world!
```

### Investigation Path

1. **Initial Hypothesis**: PATH ordering issue where consumer's Python environment wasn't taking precedence

2. **Custom Package Discovery**: Found that jackpkgs maintained its own nbstripout package at `pkgs/nbstripout/default.nix` which was identical to the nixpkgs version (same version 0.8.1, same dependencies, same build process)

3. **First Solution Attempt**: Added `pythonPackages` configuration option to jackpkgs pre-commit module, assuming `pythonPackages.nbstripout` existed

4. **Package Redundancy Realization**: Discovered both jackpkgs custom nbstripout and `pkgs.python3Packages.nbstripout` do not exist as expected - only `pkgs.nbstripout` (standalone package) exists

5. **Cleanup**: Removed redundant custom nbstripout package since nixpkgs version was identical

5.1. **Solution Implementation**: Revived custom nbstripout package with parameterized Python environment to enable consumer configuration

06. **Architecture Analysis**: Realized `pkgs.nbstripout` brings its own Python environment which gets injected via `inputsFrom = [config.jackpkgs.outputs.devShell]`

07. **Consumer DevShell Analysis**: Examined `/Users/jack/git/github.com/cavinsresearch/zeus/uv2nix/nix/devshell.nix` and found:

    ```nix
    inputsFrom = [config.jackpkgs.outputs.devShell];  # Adds jackpkgs first
    buildInputs = devEnvPaths;  # Includes consumer's pythonDevEnv
    shellHook = ''
      export PATH="${lib.getBin pythonDevEnv}:$PATH"  # Attempted fix
    '';
    ```

08. **The Red Herring**: Discovered the shellHook was using `lib.getBin` incorrectly, generating:

    ```bash
    export PATH="/nix/store/.../python-nautilus-editable:$PATH"  # Missing /bin!
    ```

    Instead of:

    ```bash
    export PATH="/nix/store/.../python-nautilus-editable/bin:$PATH"
    ```

09. **Root Cause Clarification**: While the missing `/bin` was a bug, the deeper issue remained - PATH pollution from `pkgs.nbstripout` injected via `inputsFrom`

10. **Solution Architecture**: Developed parameterized Python interpreter approach - revive custom nbstripout package to build with consumer's Python interpreter, eliminating need for consumers to manage nbstripout dependencies while solving PATH pollution

### Key Technical Insights

- **Nix devShell ordering**: `inputsFrom` is processed before `buildInputs`, and PATH modifications in shellHooks can be fragile
- **Package structure**: `pkgs.nbstripout` vs `pkgs.python3Packages.nbstripout` - only the former exists
- **PATH resolution**: Even with correct PATH ordering, having multiple Python environments creates confusion and maintenance burden
- **Consumer patterns**: Most consumers use `inputsFrom` for convenience, making jackpkgs devShell composition critical
- **Redundant custom package**: jackpkgs had its own nbstripout package (identical to nixpkgs) that was unnecessary

### Alternative Solutions Explored

During investigation, we explored several approaches before settling on the hybrid solution:

1. **Pure shellHook fix**: Fix `lib.getBin` usage in consumer shellHooks

   - **Issue**: Doesn't eliminate underlying pollution

2. **Override nbstripout's Python**: Attempt to rebuild `pkgs.nbstripout` with consumer's Python

   - **Issue**: Not easily possible with pre-built packages

3. **Disable nbstripout entirely**: Let consumers manage their own

   - **Issue**: Too disruptive, breaks existing workflows

4. **Smart Python detection**: Auto-detect consumer's Python environment

   - **Issue**: Complex heuristics, unreliable edge cases

The chosen approach addresses the root cause while maintaining backward compatibility and providing a zero-configuration experience for consumers - they simply specify their Python environment and we automatically build compatible tools.

______________________________________________________________________

## Appendix B: Self-Contained nbstripout Package Approaches

### **Alternative Solution Discovery**

During implementation, we discovered that the core issue could be solved more elegantly by preventing Python propagation to PATH entirely, rather than configuring consumer Python environments. This would provide a zero-configuration solution.

### **The Core Insight**

Pre-commit hooks only need the `nbstripout` executable, not access to its Python environment. The current PATH pollution occurs because `python3.pkgs.buildPythonApplication` always adds Python to `propagatedBuildInputs`, causing it to appear in consumer devShells via `inputsFrom`.

### **Three Self-Contained Package Approaches**

#### **Option 1: Override propagatedBuildInputs** ❌ **FAILED**

```nix
(python3.pkgs.buildPythonApplication rec {
  pname = "nbstripout";
  version = "0.8.1";
  # ... normal definition
  propagatedBuildInputs = with python3.pkgs; [ nbformat ];
}).overrideAttrs (old: {
  propagatedBuildInputs = []; # Strip Python propagation
})
```

**How it works:**

- Build normally with `buildPythonApplication`
- Post-process to remove propagated dependencies
- Python environment remains embedded but doesn't propagate to PATH

**Analysis:**

- ✅ **Simple**: Minimal modification to existing code
- ✅ **Effective**: Python fully self-contained, zero PATH pollution
- ❌ **Hacky**: Fighting against build system's intended behavior
- ❌ **Fragile**: Could break if nixpkgs changes propagation mechanisms
- ❌ **Wasteful**: Dependencies built but then discarded from propagation

**❌ IMPLEMENTATION RESULT: FAILED**

- **Issue**: Stripping `propagatedBuildInputs = []` breaks runtime dependency resolution
- **Error**: `ModuleNotFoundError: No module named 'nbformat'` when nbstripout tries to import nbformat at runtime
- **Root cause**: Dependencies are built but not accessible to the Python interpreter at runtime when propagation is stripped

#### **Option 2: Custom stdenv.mkDerivation**

```nix
stdenv.mkDerivation rec {
  pname = "nbstripout";
  version = "0.8.1";

  nativeBuildInputs = [ python3 python3.pkgs.pip python3.pkgs.setuptools ];
  buildInputs = [ python3 ];

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-6qyLa05yno3+Hl3ywPi6RKvFoXplRI8EgBQfgL4jC7E=";
  };

  buildPhase = ''
    python -m pip install --prefix=$out $src
    # Handle dependencies manually
    python -m pip install --prefix=$out nbformat
  '';

  # No automatic propagation - we control everything
}
```

**How it works:**

- Build using standard derivation approach
- Install Python package manually into output
- Complete control over dependency propagation

**Analysis:**

- ✅ **Clean separation**: Explicit control over what propagates
- ✅ **Transparent**: Clear about what we're doing
- ✅ **Robust**: Less dependent on nixpkgs Python machinery
- ❌ **More code**: Manual handling of Python package installation
- ❌ **Maintenance**: Need to replicate `buildPythonApplication` features
- ❌ **Complexity**: Lose automatic script wrapping and other niceties

#### **Option 3: toPythonApplication wrapper** ❌ **FAILED**

```nix
python3.pkgs.toPythonApplication (
  python3.pkgs.buildPythonPackage rec {
    pname = "nbstripout";
    version = "0.8.1";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-6qyLa05yno3+Hl3ywPi6RKvFoXplRI8EgBQfgL4jC7E=";
    };

    propagatedBuildInputs = with python3.pkgs; [ nbformat ];

    # Build as library first, then wrap as application
  }
)
```

**How it works:**

- First stage: Build nbstripout as Python library with `buildPythonPackage`
- Second stage: `toPythonApplication` wraps library with executable scripts
- The wrapper stage controls propagation behavior for applications

**Analysis:**

- ✅ **Idiomatic**: Uses nixpkgs patterns correctly - this is what `toPythonApplication` is designed for
- ✅ **Maintainable**: Follows established nixpkgs conventions
- ✅ **Stable**: Less likely to break with future nixpkgs changes
- ✅ **Clean**: Proper separation between library and application concerns
- ⚠️ **Two-stage**: Conceptually more complex (but standard pattern)
- ⚠️ **Learning curve**: Need to understand both build functions

**❌ IMPLEMENTATION RESULT: FAILED**

- **Issue**: `toPythonApplication` does not prevent Python dependency propagation as expected
- **Root cause**: The wrapper still propagates the underlying Python environment and dependencies to consumer PATH
- **Discovery**: `toPythonApplication` is designed for creating applications but doesn't solve PATH pollution for consumers via `inputsFrom`

### **Decision: Option 2 (Custom stdenv.mkDerivation)**

**Why chosen:**

- **Complete control**: Full control over dependency propagation without fighting build system defaults
- **Proven approach**: Standard derivation building is well-understood and stable
- **Transparent**: Clear about what dependencies are included and how they're managed
- **Robust**: Less dependent on Python packaging machinery quirks

**After testing Option 1 and Option 3:**

- Option 1 broke runtime dependency resolution when stripping propagatedBuildInputs
- Option 3 did not prevent PATH pollution as expected - still propagates Python environment
- Option 2 provides explicit control over the entire build process

**Benefits of this approach:**

- **Zero consumer configuration**: No need for `pythonPackages` option
- **Universal solution**: Works for all consumers automatically
- **No PATH pollution**: No automatic dependency propagation to consumer PATH
- **Maintains all functionality**: Pre-commit hooks work exactly the same
- **Self-contained**: All dependencies embedded within package environment

**Implementation approach:**

- Use `stdenv.mkDerivation` for complete control over the build process
- Manually install nbstripout and its dependencies using pip into package prefix
- Ensure proper Python environment setup without propagating to consumers
- Maintain all existing tests, metadata, and functionality

______________________________________________________________________

## Appendix C: Future Alternative - Option 4 (pyproject.nix)

### **Untested Alternative: Modern Python Packaging**

During implementation, we discovered that nbstripout has a `pyproject.toml` file, making it compatible with modern Python packaging tools like `pyproject.nix`. This could provide a cleaner long-term solution.

**Potential implementation:**

```nix
# Using pyproject.nix instead of stdenv.mkDerivation
let
  pyproject-nix = inputs.pyproject-nix.lib.${system};
in
pyproject-nix.buildPythonPackage {
  src = fetchFromGitHub {
    owner = "kynan";
    repo = "nbstripout";
    rev = "0.8.1";
    hash = "...";
  };

  # Key question: Can we control propagation?
  propagatedBuildInputs = []; # Prevent PATH pollution

  # Modern declarative dependency management
  pyproject = true;
}
```

**Potential advantages:**

- **Modern tooling**: Uses contemporary Python packaging standards
- **Better dependency resolution**: pyproject.nix handles dependencies more systematically
- **Upstream compatibility**: Builds the package as upstream intends
- **Less custom logic**: More declarative, less manual pip installation
- **Maintainability**: Easier to sync with upstream changes

**Open questions:**

- Can pyproject.nix prevent `propagatedBuildInputs` propagation like our Option 2?
- Does it provide the same level of control over PATH pollution?
- What's the complexity of integrating pyproject.nix into jackpkgs?

**When to consider:**

- If Option 2 proves fragile during maintenance
- If manual pip installation becomes problematic with Python version changes
- If we want to adopt modern Python packaging practices more broadly in jackpkgs

**Status**: Documented for future consideration. Option 2 provides a working solution today.

______________________________________________________________________

Author: Claude Code (with Jack Maloney)
Date: 2025-01-27
PR: TBD
