# ADR-017: pnpm2nix-nzbr Integration for Pure Node.js Builds

| Status | Accepted |
|--------|----------|
| Date | 2026-01-25 |
| Context | [PR #108](https://github.com/jmmaloney4/jackpkgs/pull/108) - TypeScript checks fail in pure Nix builds |

## Problem Statement

The TypeScript checks module fails in pure Nix builds because `node_modules` doesn't exist in the sandbox. The check derivation runs `tsc --noEmit` but expects `node_modules` to be present on the filesystem.

```
Type-checking atlas...
ERROR: node_modules not found for package: atlas

TypeScript checks require node_modules to be present.
Please run: pnpm install
```

## Decision

Use [pnpm2nix-nzbr](https://github.com/nzbr/pnpm2nix-nzbr) with the v9 support branch to build `node_modules` as a Nix derivation. This mirrors how `uv2nix` provides Python dependencies for pure Nix builds.

**Recommended flake input:**

```nix
{
  inputs.pnpm2nix.url = "github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9";
}
```

## Background: pnpm-to-Nix Ecosystem

### dream2nix

**Does NOT support pnpm lockfiles.** Only supports npm's `package-lock.json` via `nodejs-package-lock-v3`. There is no pnpm translator.

### pnpm2nix (nix-community)

**Unmaintained.** Only compatible with lockfile version 5.0 or below. pnpm v8+ uses lockfile 6.0+, and pnpm v9 uses lockfile 9.0.

### pnpm2nix-nzbr

**Actively maintained fork** with:
- Support for lockfile version 6.0+
- [PR #40](https://github.com/nzbr/pnpm2nix-nzbr/pull/40) adds v9 support (approved, available at `github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9`)
- [PR #35](https://github.com/nzbr/pnpm2nix-nzbr/pull/35) adds workspace support

## Implementation

### Phase 1: Consumer Integration

Consumers using `jackpkgs.checks.typescript` can provide their own `node_modules` via pnpm2nix-nzbr:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
    pnpm2nix.url = "github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9";
  };

  outputs = { self, nixpkgs, jackpkgs, pnpm2nix, ... }: {
    # Consumer builds node_modules and uses it in their checks
  };
}
```

### Phase 2: Module Enhancement

Add a `nodeModules` option to `checks.nix` that accepts a pnpm2nix-built derivation:

```nix
# In checks.nix options
typescript = {
  # ... existing options ...
  
  tsc = {
    # ... existing options ...
    
    nodeModules = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        A derivation containing node_modules, typically built with pnpm2nix-nzbr.
        When provided, this will be symlinked into the sandbox for TypeScript checks.
        
        Example with pnpm2nix-nzbr:
          nodeModules = pnpm2nix.lib.${system}.mkPnpmPackage {
            src = ./.;
            # ... pnpm2nix options ...
          };
      '';
    };
  };
};
```

The check derivation then symlinks the provided `node_modules`:

```nix
typescriptChecks = lib.optionalAttrs (cfg.enable && cfg.typescript.enable && tsPackages != [])
  (lib.optionalAttrs cfg.typescript.tsc.enable {
    typescript-tsc = mkCheck {
      name = "typescript-tsc";
      buildInputs = [pkgs.nodejs pkgs.nodePackages.typescript];
      setupCommands = lib.optionalString (cfg.typescript.tsc.nodeModules != null) ''
        # Link pnpm2nix-built node_modules into the sandbox
        for pkg in ${lib.escapeShellArgs tsPackages}; do
          if [ -d "${cfg.typescript.tsc.nodeModules}/node_modules" ]; then
            ln -sf "${cfg.typescript.tsc.nodeModules}/node_modules" \
              "${projectRoot}/$pkg/node_modules"
          fi
        done
      '';
      checkCommands = /* existing check commands */;
    };
  });
```

## Consumer Example

### Basic Single Package

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
    pnpm2nix.url = "github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9";
  };

  outputs = { self, nixpkgs, jackpkgs, pnpm2nix, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      # Build node_modules with pnpm2nix
      packages.${system}.nodeModules = pnpm2nix.lib.${system}.mkPnpmPackage {
        src = ./.;
        linkDevDependencies = true;
      };

      # Use it in checks
      jackpkgs.checks.typescript.tsc.nodeModules = self.packages.${system}.nodeModules;
    };
}
```

### pnpm Workspace

For monorepos with `pnpm-workspace.yaml`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
    pnpm2nix.url = "github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9";
  };

  outputs = { self, nixpkgs, jackpkgs, pnpm2nix, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      
      # Build workspace node_modules
      nodeModules = pnpm2nix.lib.${system}.mkPnpmPackage {
        src = ./.;
        linkDevDependencies = true;
        # Workspace-aware: handles pnpm-workspace.yaml automatically
      };
    in {
      packages.${system}.nodeModules = nodeModules;

      # Configure TypeScript checks with pre-built node_modules
      jackpkgs.checks.typescript = {
        enable = true;
        tsc = {
          packages = ["packages/app" "packages/lib" "tools/cli"];
          nodeModules = nodeModules;
        };
      };
    };
}
```

## Migration Path

### Current State (Workaround)

Disable TypeScript checks and run in CI:

```nix
# flake.nix
jackpkgs.checks.typescript.enable = false;
```

```yaml
# .github/workflows/typecheck.yml
jobs:
  typecheck:
    steps:
      - uses: pnpm/action-setup@v2
      - run: pnpm install
      - run: pnpm tsc --noEmit
```

### Target State

Pure Nix checks with pnpm2nix-nzbr:

```nix
{
  inputs.pnpm2nix.url = "github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9";
  
  # ... configure nodeModules as shown above ...
  
  jackpkgs.checks.typescript = {
    enable = true;
    tsc.nodeModules = nodeModules;
  };
}
```

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| v9 support not yet merged to main | Use fork branch directly: `github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9` |
| Fork maintenance uncertain | Monitor upstream; consider contributing fixes |
| Complex workspace layouts may not work | Test with simple cases first; fall back to CI-only for complex cases |
| Build failures with native dependencies | Some npm packages with native code may need additional Nix configuration |

## Alternatives Considered

### IFD (Import From Derivation)

Run `pnpm install` during Nix evaluation.

**Rejected:** Breaks pure evaluation, discouraged in Nix community, causes evaluation-time network access.

### Dual Lockfiles (npm + pnpm)

Generate `package-lock.json` alongside `pnpm-lock.yaml` and use dream2nix.

**Rejected:** Requires maintaining two lockfiles, potential for drift, may not work with pnpm workspace features.

### CI-Only Checks

Run TypeScript checks in GitHub Actions only.

**Rejected as default:** Inconsistent with Python checks (which use pure Nix with uv2nix). Acceptable as fallback.

## References

- [pnpm2nix-nzbr](https://github.com/nzbr/pnpm2nix-nzbr) - Main repository
- [pnpm2nix-nzbr v9 branch](https://github.com/wrvsrx/pnpm2nix-nzbr/tree/adapt-to-v9) - Fork with v9 support
- [PR #40: pnpm lockfile v9 support](https://github.com/nzbr/pnpm2nix-nzbr/pull/40)
- [PR #35: pnpm workspace support](https://github.com/nzbr/pnpm2nix-nzbr/pull/35)
- [uv2nix](https://github.com/pyproject-nix/uv2nix) - Similar approach for Python
