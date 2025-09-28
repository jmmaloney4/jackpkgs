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

We MUST implement a **hybrid approach (C + D)** that provides configurable Python environment support while eliminating PATH pollution:

### Core Changes

1. **Remove nbstripout from jackpkgs devShell** (Approach D)
   - nbstripout MUST NOT be included in `config.jackpkgs.outputs.devShell.buildInputs`
   - nbstripout SHOULD only be used during pre-commit hook execution
   - This eliminates PATH pollution entirely

2. **Add configurable Python environment options** (Approach C)
   - Consumers MUST be able to specify their Python package set for building Python tools
   - jackpkgs MUST support building nbstripout within consumer's Python environment
   - Default behavior MUST remain unchanged for existing consumers

### Configuration Schema

```nix
options.jackpkgs.pre-commit = {
  pythonPackages = mkOption {
    type = types.attrs;
    default = pkgs.python3Packages;
    defaultText = "pkgs.python3Packages";
    description = "Python package set to use for building Python-based tools";
  };

  buildNbstripoutFromPython = mkOption {
    type = types.bool;
    default = false;
    description = "Build nbstripout using the specified pythonPackages instead of using pkgs.nbstripout";
  };

  nbstripoutPackage = mkOption {
    type = types.package;
    default = if pcfg.buildNbstripoutFromPython
              then buildNbstripoutFromPythonPackages pcfg.pythonPackages
              else pkgs.nbstripout;
    description = "nbstripout package to use for pre-commit hooks";
  };
};
```

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

- **Eliminates PATH Pollution**: No more conflicting Python environments in consumer devShells
- **Environment Isolation**: Consumer Python environments work correctly without interference
- **Flexibility**: Consumers can choose between system nbstripout or building with their Python environment
- **Performance**: Heavy packages (numpy, pytorch) only rebuild when actually needed
- **Backward Compatibility**: Existing consumers continue working without changes

### Trade-offs

- **Implementation Complexity**: More configuration options and conditional logic in jackpkgs
- **Documentation Burden**: Need clear guidance on when/how to use different options
- **Testing Surface**: Additional configuration combinations to test

### Risks & Mitigations

**Risk**: Building nbstripout from scratch increases consumer build times
- **Mitigation**: Make it opt-in via `buildNbstripoutFromPython = false` by default

**Risk**: Consumers may not understand when to enable Python environment integration
- **Mitigation**: Provide clear documentation with decision tree and examples

**Risk**: Breaking changes for consumers who rely on nbstripout being in devShell PATH
- **Mitigation**: Document migration path and provide transition period

## Alternatives Considered

### Alternative A — Consumer Provides Their Own nbstripout

- **Pros**: Simple delegation to consumer, no jackpkgs complexity
- **Cons**: Requires all consumers to add nbstripout to their dependencies, breaks existing workflows
- **Why not chosen**: Too disruptive for existing consumers, shifts complexity to every consumer

### Alternative B — Conditional Python Environment

- **Pros**: Automatic integration when consumer provides Python environment
- **Cons**: Complex circular dependency issues, unclear fallback behavior
- **Why not chosen**: Fragile dependency resolution, hard to debug failures

### Alternative C — Build nbstripout in Consumer's Python Environment (Chosen)

- **Pros**: Uses consumer's Python without requiring them to manage nbstripout dependency
- **Cons**: Additional build complexity in jackpkgs
- **Why chosen**: Balances flexibility with ease of use

### Alternative D — DevShell Separation (Chosen)

- **Pros**: Completely eliminates PATH pollution, clean separation of concerns
- **Cons**: Changes where nbstripout is available (pre-commit only, not interactive shell)
- **Why chosen**: Addresses root cause rather than symptoms

### Alternative E — ShellHook PATH Manipulation

- **Pros**: Consumer-side fix, no jackpkgs changes needed
- **Cons**: Fragile, doesn't eliminate pollution, requires every consumer to implement
- **Why not chosen**: Treats symptoms not cause, discovered to be unreliable due to PATH ordering issues

## Implementation Plan

### Phase 1: Core Infrastructure
- **Owner**: jackpkgs maintainers
- Implement `buildNbstripoutFromPython` option with conditional package building
- Remove nbstripout from `config.jackpkgs.outputs.devShell.buildInputs`
- Ensure pre-commit hooks continue using nbstripout correctly
- **Dependencies**: None
- **Timeline**: 1-2 weeks

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

10. **Solution Architecture**: Developed hybrid approach to eliminate pollution at source while providing consumer flexibility

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

The chosen hybrid approach addresses the root cause while maintaining backward compatibility and consumer choice.

---

Author: Claude Code (with Jack Maloney)
Date: 2025-01-27
PR: TBD