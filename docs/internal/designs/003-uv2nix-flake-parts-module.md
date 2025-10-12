# ADR-003: uv2nix Flake-Parts Module

## Status

Accepted

## Context

### Problem Statement

The cavinsresearch/zeus project recently integrated uv2nix for Python environment management, creating a comprehensive setup in `zeus/nix/python.nix`. This implementation includes:
- Python workspace loading with uv2nix
- Darwin-specific SDK version handling (15.0)
- Custom stdenv for macOS builds
- pyproject-build-systems integration
- Setuptools fixes for problematic packages
- Multiple environment variants (default, jupyter, editable)
- Exposed module args for workspace and environments

This pattern is valuable and should be reusable across other projects, but currently requires ~187 lines of non-trivial Nix code that must be duplicated and maintained separately in each consuming project.

### Specific Requirements Identified

From zeus implementation, we need to support:

1. **Multi-input coordination**: uv2nix, pyproject-nix, pyproject-build-systems
2. **Platform-specific configuration**: Darwin SDK versions, custom stdenv
3. **Workspace management**: Loading from pyproject.toml and uv.lock
4. **Package fixes**: Setuptools additions for broken packages
5. **Multiple environments**: Default, development with extras, editable dev environments
6. **Module exports**: Workspace utilities and environment packages as module args
7. **Package outputs**: Named packages for each environment

### Constraints

- **Technical**: Must work with flake-parts module system
- **Compatibility**: Should match zeus implementation behavior exactly
- **Flexibility**: Need configurability for edge cases while maintaining sensible defaults
- **Maintainability**: Should be highly opinionated to reduce configuration surface
- **Integration**: Must compose with existing jackpkgs modules (devshell, pre-commit, etc.)

### Prior Art

- jackpkgs has 6 existing flake-parts modules (fmt, just, pre-commit, shell, pulumi, quarto)
- All follow the pattern: `{jackpkgsInputs}` → module definition with options and config
- Modules expose outputs via `jackpkgs.outputs.*` and compose via `jackpkgs.shell.inputsFrom`
- ADR-002 recently addressed Python environment PATH pollution in pre-commit hooks

## Decision

We MUST create a **highly-opinionated, reusable uv2nix flake-parts module** at `jackpkgs/modules/flake-parts/python.nix` (exposed as `jackpkgs.python`) that encapsulates the zeus implementation pattern with minimal required configuration.

### Core Principles

1. **Opinionated Defaults**: Sensible defaults for 95% use case
   - Python 3.12
   - Wheel source preference
   - Darwin SDK 15.0
   - pyproject-build-systems integration when available

2. **Minimal Configuration**: Most projects should only need:
  ```nix
  jackpkgs.python.enable = true;
  jackpkgs.python.environments = {
     default.name = "my-python-env";
   };
   ```

3. **Escape Hatches**: Advanced users can override any behavior
4. **Zero Breaking Changes**: Existing jackpkgs consumers unaffected

### Configuration Schema

```nix
options.jackpkgs.python = {
  enable = mkEnableOption "opinionated Python environment management (uv2nix-backed)" // {default = false;};

  # Paths
  pyprojectPath = mkOption {
    type = types.str;
    default = "./pyproject.toml";
    description = "Path to pyproject.toml file (resolved relative to project root when enabled)";
  };

  uvLockPath = mkOption {
    type = types.str;
    default = "./uv.lock";
    description = "Path to uv.lock file (resolved relative to project root when enabled)";
  };

  workspaceRoot = mkOption {
    type = types.str;
    default = ".";
    description = "Root directory of the uv workspace (resolved relative to project root when enabled)";
  };

  # Python configuration
  pythonPackage = mkOption {
    type = types.package;
    default = pkgs.python312;
    defaultText = "pkgs.python312";
    description = "Python package to use as base interpreter";
  };

  # Darwin-specific
  darwin.sdkVersion = mkOption {
    type = types.str;
    default = "15.0";
    description = "macOS SDK version for Darwin builds";
  };

  # Package fixes
  setuptools.packages = mkOption {
    type = types.listOf types.str;
    default = ["peewee" "multitasking" "sgmllib3k"];
    description = "List of packages that need setuptools added to nativeBuildInputs";
  };

  # Build configuration
  sourcePreference = mkOption {
    type = types.enum ["wheel" "sdist"];
    default = "wheel";
    description = "Prefer wheels or source distributions when available";
  };

  extraOverlays = mkOption {
    type = types.listOf types.unspecified;
    default = [];
    description = "Additional overlays to apply to the Python package set";
  };

  # Environment definitions
  environments = mkOption {
    type = types.attrsOf (types.submodule {
      options = {
        name = mkOption {
          type = types.str;
          description = "Name of the virtual environment and package output";
        };

        extras = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Optional dependency groups to include (e.g., 'jupyter', 'dev')";
        };

        editable = mkOption {
          type = types.bool;
          default = false;
          description = "Create editable install with workspace members";
        };

        editableRoot = mkOption {
          type = types.str;
          default = "$REPO_ROOT";
          description = "Root path for editable installs (supports shell variables)";
        };

        members = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Specific workspace members to make editable (null = all)";
        };

        spec = mkOption {
          type = types.nullOr types.unspecified;
          default = null;
          description = "Custom dependency spec (overrides extras-based spec)";
        };
      };
    });
    default = {};
    description = "Python virtual environments to create";
    example = {
      default = {
        name = "python-env";
      };
      jupyter = {
        name = "python-jupyter";
        extras = ["jupyter"];
      };
      dev = {
        name = "python-dev";
        editable = true;
      };
    };
  };

  # Output configuration
  outputs = {
    exposeWorkspace = mkOption {
      type = types.bool;
      default = true;
      description = "Expose pythonWorkspace as perSystem module arg";
    };

    exposeEnvs = mkOption {
      type = types.bool;
      default = true;
      description = "Expose pythonEnvs as perSystem module arg";
    };

    addToDevShell = mkOption {
      type = types.bool;
      default = false;
      description = "Add default environment to jackpkgs devShell via inputsFrom";
    };
  };
};
```

### Implementation Architecture

The module will:

1. **Check preconditions**: Verify uv2nix, pyproject-nix inputs exist and files are present
2. **Load workspace**: Use `uv2nix.lib.workspace.loadWorkspace`
3. **Configure stdenv**: Apply Darwin SDK version on macOS platforms
4. **Build Python set**: Create base with `pyproject-nix.build.packages`
5. **Apply overlays**: Compose base overlay + build-systems + setuptools fixes + extra overlays
6. **Create environments**: Build each defined environment (standard or editable)
7. **Export outputs**:
   - `packages.<name>` for each environment
   - `_module.args.pythonWorkspace` with utilities
   - `_module.args.pythonEnvs` with environment attrset
   - Optionally `jackpkgs.outputs.pythonDevShell`

### Key Technical Details

**stdenv Darwin handling** (from zeus):
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

**Setuptools fix overlay** (from zeus):
```nix
ensureSetuptools = final: prev: let
  add = name:
    lib.optionalAttrs (prev ? ${name}) {
      ${name} = prev.${name}.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [final.setuptools];
      });
    };
in
  lib.foldl' lib.recursiveUpdate {} (map add cfg.setuptools.packages);
```

**Environment creation helpers**:
```nix
pythonWorkspace = {
  inherit workspace pythonSet;
  inherit projectName defaultSpec;

  # Helper to add extras to spec
  specWithExtras = extras: /* ... */;

  # Create environment from spec
  mkEnvForSpec = {name, spec}: /* ... */;

  # Create environment with extras
  mkEnv = {name, extras ? [], spec ? null}: /* ... */;

  # Create editable environment
  mkEditableEnv = {name, extras ? [], spec ? null, members ? null, root ? "$REPO_ROOT"}: /* ... */;
};
```

### Scope

**In Scope:**
- Complete uv2nix workspace setup automation
- Darwin SDK configuration
- Package fix mechanisms (setuptools, custom overlays)
- Multiple environment creation (standard and editable)
- Module arg exports for advanced use cases
- Package outputs for all environments
- Optional devShell integration

**Out of Scope:**
- Support for Python package managers other than uv (poetry2nix, mach-nix, etc.)
- Jupyter kernel registration (handled by separate jupyenv module)
- Pre-commit hook Python environment (addressed in ADR-002)
- Python version management across multiple versions simultaneously
- Custom Python patches or alternative interpreters (PyPy, etc.)

## Consequences

### Benefits

- **Reusability**: 187 lines of complex Nix become ~10 lines of configuration
- **Maintainability**: Single source of truth for uv2nix patterns
- **Consistency**: All jackpkgs consumers use same approach
- **Lower Barrier**: Teams can adopt uv2nix without deep Nix knowledge
- **Evolution**: Improvements benefit all consumers automatically
- **Testing**: Single module can be thoroughly tested vs. duplicated code
- **Documentation**: One module to document vs. explaining pattern repeatedly

### Trade-offs

- **Abstraction Overhead**: Module adds layer between consumer and uv2nix
- **Configuration Complexity**: Options system may be harder to understand than direct code
- **Flexibility vs Simplicity**: Balancing escape hatches with opinionated defaults
- **Breaking Changes**: Future uv2nix changes require module updates
- **Debugging**: Errors may be less transparent through module layer
- **Maintenance Burden**: jackpkgs team owns this integration pattern

### Risks & Mitigations

**Risk**: uv2nix API changes break the module
- **Mitigation**: Pin uv2nix version, test against updates before bumping, maintain compatibility layer

**Risk**: Opinionated defaults don't fit all use cases
- **Mitigation**: Provide comprehensive escape hatches (extraOverlays, custom spec, etc.), document advanced patterns

**Risk**: Module complexity grows to match all zeus edge cases
- **Mitigation**: Start minimal, add features only when multiple consumers need them, maintain "simple things simple" principle

**Risk**: Debugging environment issues becomes harder through abstraction
- **Mitigation**: Expose pythonWorkspace for manual debugging, provide clear error messages, document troubleshooting

**Risk**: Darwin SDK version becomes outdated
- **Mitigation**: Make configurable with reasonable default, document why it exists

## Alternatives Considered

### Alternative A — Keep Pattern Duplicated

- **Pros**: No abstraction overhead, maximum flexibility per-project, no central maintenance
- **Cons**: Code duplication, inconsistent approaches, harder to improve pattern, higher onboarding cost
- **Why not chosen**: Violates DRY principle, wastes engineering time re-implementing same logic

### Alternative B — Minimal Helper Functions Only

Provide `jackpkgs.lib.uv2nix.*` helper functions instead of full module:
- **Pros**: Lower abstraction, more explicit, easier to understand
- **Cons**: Consumers still write boilerplate, doesn't integrate with flake-parts ecosystem, no standard outputs
- **Why not chosen**: Doesn't reduce configuration burden enough, misses flake-parts composition benefits

### Alternative C — Full Python Environment Manager

Support multiple Python tools (uv2nix, poetry2nix, mach-nix) in one unified module:
- **Pros**: Maximum flexibility, one module for all Python needs
- **Cons**: Massive complexity, conflicting paradigms, maintenance nightmare, unclear defaults
- **Why not chosen**: Scope too large, each tool has different philosophies, better as separate modules if needed

### Alternative D — zeus-Specific Module (Chosen Approach)

Create highly opinionated module based on zeus implementation, with clear escape hatches:
- **Pros**: Proven pattern, clear defaults, solves real use case, maintainable scope, easy to extend
- **Cons**: Opinionated (but that's intentional), may not fit all projects (but provides overrides)
- **Why chosen**: Best balance of reusability, maintainability, and simplicity; based on real production usage

## Implementation Plan

### Phase 1: Core Module Implementation
- **Owner**: jackpkgs maintainers
- Create `modules/flake-parts/python.nix` with options schema
- Implement workspace loading and Python set creation
- Implement environment builders (mkEnv, mkEditableEnv)
- Add setuptools fix overlay
- Export packages and module args
- **Dependencies**: None
- **Timeline**: 1-2 days

### Phase 2: Integration & Testing
- **Owner**: jackpkgs maintainers
- Add module to `modules/flake-parts/all.nix` and `default.nix`
- Update jackpkgs flake.nix to make uv2nix inputs optional
- Test with minimal configuration
- Test with zeus-equivalent configuration
- Test on both Linux and Darwin
- **Dependencies**: Phase 1
- **Timeline**: 1 day

### Phase 3: zeus Migration
- **Owner**: zeus project maintainers
- Replace `zeus/nix/python.nix` with module configuration
- Verify all environments build identically
- Verify module args are available
- Update zeus flake.nix to use module
- **Dependencies**: Phase 2
- **Timeline**: 1 day

### Phase 4: Documentation
- **Owner**: jackpkgs maintainers
- Document module options and examples
- Create migration guide from manual setup
- Document common patterns (extras, editable, custom overlays)
- Document troubleshooting
- **Dependencies**: Phase 3
- **Timeline**: 1 day

### Phase 5: Optional Enhancements
- **Owner**: jackpkgs maintainers
- devShell integration option
- Additional environment customization hooks
- Performance optimizations
- **Dependencies**: Phase 4
- **Timeline**: Ongoing as needed

### Rollout Considerations

- **Opt-in**: Module disabled by default, consumers choose to enable
- **Input Management**: jackpkgs should make uv2nix inputs optional (only required when module enabled)
- **Gradual Adoption**: Projects can migrate at their own pace
- **Backward Compatibility**: zeus can keep old implementation temporarily during validation

### Rollback Plan

- **Immediate**: Disable module in consumer flake.nix, revert to direct implementation
- **Module Issues**: Fix in jackpkgs, consumers can pin old version temporarily
- **Design Issues**: Module can be deprecated, consumers keep working implementations
- **No Risk**: Module is purely additive, doesn't affect non-users

## Related

- **ADR-002**: Python Environment Configuration for Pre-commit Hooks - established patterns for Python environment handling in jackpkgs
- **zeus/nix/python.nix**: Source implementation for this module
- **Upstream**: [uv2nix](https://github.com/adisbladis/uv2nix), [pyproject-nix](https://github.com/pyproject-nix/pyproject.nix)
- **Future**: Could inform similar modules for poetry2nix or other Python tools if needed

---

## Appendix A: zeus Implementation Reference

### Current zeus Configuration (187 lines)

```nix
# zeus/nix/python.nix
{inputs, ...}: {
  perSystem = {pkgs, lib, ...}: let
    pyprojectPath = ../pyproject.toml;
    uvLockPath = ../uv.lock;

    # ... 180 more lines of workspace loading, overlay composition, environment creation
  in {
    packages.python-nautilus = pythonEnvs.default;
    packages.python-nautilus-jupyter = pythonEnvs.jupyter;
    packages.python-nautilus-editable = pythonEnvs.editable;

    _module.args.pythonWorkspace = pythonWorkspace;
    _module.args.pythonEnvs = pythonEnvs;
  };
}
```

### Equivalent Module Configuration (~15 lines)

```nix
# zeus/flake.nix (imports section)
imports = [
  # ... other modules
];

# zeus/flake.nix (config section)
jackpkgs.python = {
  enable = true;
  environments = {
    default.name = "python-nautilus";
    jupyter = {
      name = "python-nautilus-jupyter";
      extras = ["jupyter"];
    };
    editable = {
      name = "python-nautilus-editable";
      editable = true;
    };
  };
};
```

**Lines saved**: 172 (92% reduction)
**Complexity reduced**: High → Low
**Maintainability**: Duplicated → Centralized

### Key Features Preserved

✅ Darwin SDK 15.0 handling
✅ Python 3.12 base
✅ Wheel source preference
✅ pyproject-build-systems integration
✅ Setuptools fixes for peewee, multitasking, sgmllib3k
✅ Three environment variants
✅ pythonWorkspace module arg with utilities
✅ pythonEnvs module arg
✅ Package outputs for all environments

### Additional Features Gained

✅ Configurable Python version
✅ Configurable Darwin SDK version
✅ Configurable setuptools packages
✅ Extra overlays support
✅ Custom spec support
✅ Optional devShell integration
✅ Better error messages
✅ Centralized maintenance

---

## Appendix B: Module File Structure

```
jackpkgs/
├── modules/
│   └── flake-parts/
│       ├── all.nix              # Add python module import
│       ├── default.nix          # Add python to flakeModules
│       └── python.nix          # Core implementation
├── flake.nix                    # Make uv2nix inputs optional
└── docs/
    └── internal/
        └── designs/
            └── 003-uv2nix-flake-parts-module.md  # This ADR
```

### Optional Inputs Pattern

```nix
# jackpkgs/flake.nix
{
  inputs = {
    # ... existing inputs

    # Optional: uv2nix support
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:adisbladis/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };
}
```

Module checks for inputs availability:
```nix
config = mkIf cfg.enable {
  assertions = [
    {
      assertion = inputs ? uv2nix;
      message = "jackpkgs.python requires uv2nix input (see jackpkgs documentation)";
    }
    {
      assertion = inputs ? pyproject-nix;
      message = "jackpkgs.python requires pyproject-nix input (see jackpkgs documentation)";
    }
  ];
  # ... rest of config
};
```

---

Author: Jack Maloney (with Claude Code)
Date: 2025-09-30
PR: TBD
