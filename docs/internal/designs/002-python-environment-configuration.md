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

We MUST implement a **parameterized Python environment approach** that provides configurable Python interpreter support while eliminating PATH pollution:

### Core Implementation

1. **Parameterized Custom nbstripout Package**
   - Revive jackpkgs custom nbstripout package with `python3` parameter
   - Build nbstripout using consumer's Python interpreter and its package set
   - Consumer does NOT need to add nbstripout to their Python dependencies
   - Our package handles dependency resolution automatically

2. **Configurable Python Environment Options**
   - Consumers MUST be able to specify their Python package set
   - jackpkgs automatically extracts Python interpreter and builds nbstripout with it
   - nbstripout uses consumer's Python interpreter → eliminates PATH pollution
   - Default behavior MUST remain unchanged for existing consumers

### Key Technical Insight

The solution works by **using the consumer's Python interpreter** rather than requiring nbstripout in their dependencies. Our custom package:
- Takes `pythonPackages.python` (the interpreter)
- Uses `python3.pkgs.buildPythonApplication` with that interpreter
- Resolves dependencies (`nbformat`) from that Python's package set
- Produces nbstripout that uses the same Python environment as consumer's project

### Configuration Schema

```nix
options.jackpkgs.pre-commit = {
  pythonPackages = mkOption {
    type = types.attrs;
    default = pkgs.python3Packages;
    defaultText = "pkgs.python3Packages";
    description = "Python package set to use for Python-based tools";
  };

  nbstripoutPackage = mkOption {
    type = types.package;
    default = pkgs.callPackage ../../pkgs/nbstripout {
      python3 = config.jackpkgs.pre-commit.pythonPackages.python;
    };
    description = "nbstripout package built with the configured Python interpreter. Uses consumer's Python environment automatically - no need to add nbstripout to consumer dependencies.";
  };
};
```

### Custom nbstripout Package

```nix
# pkgs/nbstripout/default.nix
{
  lib,
  python3 ? python3,  # Parameterized Python interpreter
  fetchPypi,
  # ... other dependencies
}:
python3.pkgs.buildPythonApplication rec {
  # Builds nbstripout using the provided Python interpreter
  # Dependencies (nbformat) come from that Python's package set
  propagatedBuildInputs = with python3.pkgs; [ nbformat ];
  # ... rest of package definition
}
```

**How it works:**
- Takes ANY Python interpreter as `python3` parameter
- Uses `python3.pkgs.buildPythonApplication` to build with that interpreter
- Resolves `nbformat` dependency from that Python's package set
- **Consumer doesn't need nbstripout in their dependencies** - we build it for them
- Result: nbstripout executable uses consumer's Python interpreter

### Scope

**In Scope:**
- Configurable Python environment for nbstripout
- Elimination of PATH pollution from jackpkgs devShell
- Backward compatibility for existing consumers
- Support for uv2nix, poetry2nix, and other Python environment managers

**Out of Scope:**
- Automatic detection of consumer's Python environment
- Migration of other Python tools beyond nbstripout
- Changes to consumer devShell configuration patterns

## Consequences

### Benefits

- **Eliminates PATH Pollution**: nbstripout uses consumer's Python interpreter - no separate Python environment in PATH
- **Environment Isolation**: All Python tools resolve to the same interpreter and environment
- **Zero Consumer Dependencies**: Consumers don't need to add nbstripout to their Python dependencies - we build it automatically
- **Performance**: Only nbstripout rebuilds with consumer's Python - heavy packages (numpy, pytorch) unaffected unless Python version changes
- **Backward Compatibility**: Existing consumers continue working without changes (defaults to pkgs.python3)
- **Universal Compatibility**: Works with any Python environment manager (uv2nix, poetry2nix, mach-nix, etc.)

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

---

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

6. **Architecture Analysis**: Realized `pkgs.nbstripout` brings its own Python environment which gets injected via `inputsFrom = [config.jackpkgs.outputs.devShell]`

7. **Consumer DevShell Analysis**: Examined `/Users/jack/git/github.com/cavinsresearch/zeus/uv2nix/nix/devshell.nix` and found:
   ```nix
   inputsFrom = [config.jackpkgs.outputs.devShell];  # Adds jackpkgs first
   buildInputs = devEnvPaths;  # Includes consumer's pythonDevEnv
   shellHook = ''
     export PATH="${lib.getBin pythonDevEnv}:$PATH"  # Attempted fix
   '';
   ```

8. **The Red Herring**: Discovered the shellHook was using `lib.getBin` incorrectly, generating:
   ```bash
   export PATH="/nix/store/.../python-nautilus-editable:$PATH"  # Missing /bin!
   ```
   Instead of:
   ```bash
   export PATH="/nix/store/.../python-nautilus-editable/bin:$PATH"
   ```

9. **Root Cause Clarification**: While the missing `/bin` was a bug, the deeper issue remained - PATH pollution from `pkgs.nbstripout` injected via `inputsFrom`

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

---

Author: Claude Code (with Jack Maloney)
Date: 2025-01-27
PR: TBD