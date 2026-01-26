# ADR-017: dream2nix for Pure Node.js Dependency Management

## Status

Proposed

## Context

### Problem

The `typescript-tsc` check from the checks module (ADR-016) fails in pure Nix builds because `node_modules` doesn't exist in the sandbox:

```
Type-checking atlas...
ERROR: node_modules not found for package: atlas

TypeScript checks require node_modules to be present.
Please run: pnpm install
```

In a pure Nix derivation, there's no access to the host filesystem. The `node_modules` directory created by `pnpm install` during development doesn't exist in the Nix sandbox.

### Current State

The `checks.nix` module currently:
1. Discovers pnpm workspace packages from `pnpm-workspace.yaml`
2. Runs `tsc --noEmit` on each package
3. **Fails** because it expects `node_modules` to exist (line 412-423 in checks.nix)

This contrasts with Python checks, which work because:
- Python dependencies are built as Nix derivations via `uv2nix`
- The Python environment is passed to checks via `pythonEnvWithDevTools`
- No reliance on host filesystem state

### Why dream2nix

[dream2nix](https://github.com/nix-community/dream2nix) is a framework for building packages from various language ecosystems in Nix. For Node.js, it can:

1. **Parse lockfiles** - Reads `pnpm-lock.yaml` to determine exact dependency versions
2. **Build node_modules as a Nix derivation** - Creates a reproducible, cacheable `node_modules` directory
3. **Support pnpm workspaces** - Handles monorepo structures with multiple packages
4. **Integrate with flake-parts** - Provides a flake-parts module for easy integration

### Alternatives to dream2nix

| Tool | Maturity | pnpm Support | Workspace Support | Maintenance |
|------|----------|--------------|-------------------|-------------|
| dream2nix | High | Yes | Yes | Active (nix-community) |
| pnpm2nix | Low | Yes | Limited | Stale |
| npmlock2nix | Medium | No (npm only) | Limited | Low activity |
| node2nix | High | No (npm only) | Yes | Maintained |

dream2nix is the best choice for pnpm workspaces due to its active maintenance and explicit pnpm support.

---

## Decision

### Core Design

Integrate dream2nix to build `node_modules` as a Nix derivation that can be provided to TypeScript checks. This mirrors how `uv2nix` provides Python dependencies.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Consumer flake.nix                          │
├─────────────────────────────────────────────────────────────────┤
│  inputs.dream2nix.url = "github:nix-community/dream2nix";       │
│  jackpkgs.checks.typescript.nodeModules = dream2nixNodeModules; │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    jackpkgs checks.nix                           │
├─────────────────────────────────────────────────────────────────┤
│  typescript-tsc check uses provided nodeModules derivation      │
│  Links/copies node_modules into package directories             │
│  Runs tsc --noEmit with proper dependency resolution            │
└─────────────────────────────────────────────────────────────────┘
```

### Option 1: Consumer-Provided node_modules (Recommended)

The checks module accepts an optional `nodeModules` derivation from the consumer. This keeps dream2nix integration in consumer projects, not jackpkgs.

```nix
# In consumer flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
    dream2nix.url = "github:nix-community/dream2nix";
  };

  outputs = inputs @ {self, nixpkgs, jackpkgs, dream2nix, ...}: {
    # ... flake config ...
  };
}
```

```nix
# In consumer flake-module.nix
{ inputs, config, lib, ... }: {
  imports = [
    inputs.jackpkgs.flakeModules.default
  ];

  perSystem = { pkgs, system, ... }: let
    # Build node_modules using dream2nix
    dream2nixOutputs = inputs.dream2nix.lib.makeFlakeOutputs {
      systems = [system];
      config.projectRoot = ./.;
      source = ./.;
      projects = {
        my-project = {
          name = "my-project";
          relPath = "";
          subsystem = "nodejs";
          translator = "pnpm-lock";
        };
      };
    };

    # Extract the node_modules derivation
    nodeModules = dream2nixOutputs.packages.${system}.my-project.lib.node_modules;
  in {
    jackpkgs.checks.typescript = {
      enable = true;
      tsc.nodeModules = nodeModules;  # NEW: provide node_modules derivation
    };
  };
}
```

### Option 2: Built-in dream2nix Integration

jackpkgs could accept dream2nix as an optional input and handle the integration internally.

```nix
# In jackpkgs checks.nix options
jackpkgs.checks.typescript = {
  enable = mkEnableOption "TypeScript checks";

  nodeModules = {
    # Option A: Pre-built derivation (recommended)
    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "Pre-built node_modules derivation (e.g., from dream2nix)";
    };

    # Option B: Build from lockfile (requires dream2nix input)
    fromLockfile = {
      enable = mkEnableOption "Build node_modules from pnpm-lock.yaml";
      lockfilePath = mkOption {
        type = types.str;
        default = "./pnpm-lock.yaml";
        description = "Path to pnpm-lock.yaml relative to project root";
      };
    };
  };
};
```

### Implementation Details

#### Modified TypeScript Check

```nix
# In checks.nix - updated typescript-tsc check
typescript-tsc = mkCheck {
  name = "typescript-tsc";
  buildInputs = [pkgs.nodejs pkgs.nodePackages.typescript];
  setupCommands = lib.optionalString (cfg.typescript.tsc.nodeModules != null) ''
    # Link node_modules from the provided derivation
    # This handles both root-level and per-package node_modules
    ${linkNodeModules cfg.typescript.tsc.nodeModules projectRoot tsPackages}
  '';
  checkCommands =
    lib.concatMapStringsSep "\n" (pkg: ''
      echo "Type-checking ${pkg}..."
      cd ${lib.escapeShellArg "${projectRoot}/${pkg}"}
      tsc --noEmit ${lib.escapeShellArgs cfg.typescript.tsc.extraArgs}
    '')
    tsPackages;
};
```

#### Node Modules Linking Strategy

For pnpm workspaces, `node_modules` structure varies:

1. **Hoisted dependencies** - Shared dependencies at workspace root
2. **Per-package node_modules** - Package-specific dependencies with symlinks

The linking function must handle both:

```nix
# Helper to link node_modules into the sandbox
linkNodeModules = nodeModules: projectRoot: packages: ''
  # Link root node_modules if it exists in the derivation
  if [ -d "${nodeModules}/node_modules" ]; then
    ln -sfn "${nodeModules}/node_modules" "${projectRoot}/node_modules"
  fi

  # Link per-package node_modules
  ${lib.concatMapStringsSep "\n" (pkg: ''
    pkg_node_modules="${nodeModules}/${pkg}/node_modules"
    if [ -d "$pkg_node_modules" ]; then
      mkdir -p "${projectRoot}/${pkg}"
      ln -sfn "$pkg_node_modules" "${projectRoot}/${pkg}/node_modules"
    fi
  '') packages}
'';
```

### dream2nix Configuration for pnpm Workspaces

Example dream2nix configuration for a typical pnpm monorepo:

```nix
# dream2nix.nix - can be imported by consumer projects
{ dream2nix, source, ... }:

dream2nix.lib.makeFlakeOutputs {
  systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
  config.projectRoot = source;
  source = source;

  # Auto-detect projects from pnpm-workspace.yaml
  autoProjects = true;

  # Or explicit project configuration:
  projects = {
    workspace-root = {
      name = "my-monorepo";
      relPath = "";
      subsystem = "nodejs";
      translator = "pnpm-lock";

      # Subsystem-specific settings
      subsystemInfo = {
        nodejs = 20;  # Node.js version
      };
    };
  };

  # Package overrides (if needed)
  packageOverrides = {
    # Handle packages with native dependencies
    sharp = {
      add-inputs = {
        nativeBuildInputs = old: old ++ [pkgs.pkg-config pkgs.vips];
      };
    };
  };
};
```

### Migration Path for Existing Projects

#### Step 1: Add dream2nix Input

```nix
# flake.nix
inputs.dream2nix.url = "github:nix-community/dream2nix";
```

#### Step 2: Configure dream2nix

```nix
# Create dream2nix.nix or add to flake-module.nix
# See example above
```

#### Step 3: Update jackpkgs Configuration

```nix
jackpkgs.checks.typescript.tsc.nodeModules = dream2nixNodeModules;
```

#### Step 4: Remove Workaround

```nix
# Remove this:
# jackpkgs.checks.typescript.enable = false;
```

---

## Consequences

### Benefits

1. **Pure Nix builds** - TypeScript checks work in `nix flake check` without IFD
2. **Reproducibility** - Exact same dependencies in CI as development
3. **Caching** - `node_modules` derivation is cached by Nix
4. **Consistency** - Same pattern as Python (uv2nix provides deps, checks use them)
5. **No host state** - No reliance on `pnpm install` being run beforehand

### Trade-offs

1. **Additional input** - Consumers must add dream2nix to their flake
2. **Learning curve** - dream2nix has its own configuration model
3. **Build time** - First build of node_modules takes time (cached thereafter)
4. **Native deps complexity** - Packages with native dependencies need overrides

### Risks & Mitigations

**R1: dream2nix API instability**
- Risk: dream2nix is still evolving; API may change
- Mitigation: Recommend specific version pins in consumer flakes
- Mitigation: Document known-good versions

**R2: Complex monorepo structures**
- Risk: Some pnpm workspace configurations may not work
- Mitigation: Provide fallback to explicit node_modules derivation
- Mitigation: Document tested configurations

**R3: Native dependency hell**
- Risk: Packages like `sharp`, `sqlite3` need special handling
- Mitigation: Document common overrides
- Mitigation: Consider maintaining override library in jackpkgs

**R4: Performance concerns**
- Risk: Building node_modules in Nix is slower than pnpm
- Mitigation: Leverages Nix cache; only rebuilds on lockfile change
- Mitigation: Optional; projects can still disable checks

---

## Alternatives Considered

### Alternative A — IFD (Import From Derivation)

Run `pnpm install` as part of building the check derivation.

```nix
# Conceptual - not recommended
nodeModulesIFD = pkgs.runCommand "node-modules-ifd" {
  buildInputs = [pkgs.pnpm pkgs.nodejs];
  src = ./.;
} ''
  cp -r $src/* .
  pnpm install --frozen-lockfile
  cp -r node_modules $out
'';
```

**Pros:**
- Simpler; uses pnpm directly
- No additional flake input

**Cons:**
- IFD has evaluation-time implications
- Network access during evaluation (or FOD complexity)
- Less pure; depends on pnpm version

**Why not chosen:** IFD is discouraged for flake checks; dream2nix provides a purer solution.

### Alternative B — CI-Only TypeScript Checks

Remove TypeScript from `nix flake check`; run in GitHub Actions instead.

```yaml
# .github/workflows/ci.yml
- run: pnpm install
- run: pnpm tsc --noEmit
```

**Pros:**
- Simple; no Nix complexity
- Matches how most JS projects work
- No additional dependencies

**Cons:**
- Inconsistent with Python checks (which work in Nix)
- Loses Nix-based reproducibility
- Different check mechanisms for different languages

**Why not chosen:** jackpkgs value prop is Nix-native CI; this would be a retreat.

### Alternative C — Check Only With Pre-existing node_modules

Keep current behavior but improve error message and documentation.

**Pros:**
- Zero changes to jackpkgs
- Works for IFD-tolerant configurations
- Simple

**Cons:**
- Checks fail in pure Nix builds
- Not a real solution

**Why not chosen:** Doesn't solve the problem; just documents the limitation.

### Alternative D — Vendored node_modules in Repo

Commit `node_modules` to the repository.

**Pros:**
- Works with current check implementation
- No build-time complexity

**Cons:**
- Terrible practice; bloats repo
- Security concerns
- Update nightmare

**Why not chosen:** This is an anti-pattern.

---

## Implementation Plan

### Phase 1: Add nodeModules Option to checks.nix

1. Add `jackpkgs.checks.typescript.tsc.nodeModules` option
2. Modify typescript-tsc check to use provided nodeModules
3. Implement `linkNodeModules` helper function
4. Keep existing error message as fallback when nodeModules is null

**Deliverable:** TypeScript checks work when consumer provides nodeModules derivation

### Phase 2: Documentation and Examples

1. Document dream2nix integration pattern
2. Provide example `dream2nix.nix` for common configurations
3. Add migration guide to ADR
4. Update README with TypeScript check requirements

**Deliverable:** Clear path for consumers to adopt dream2nix

### Phase 3: Optional Built-in dream2nix Support

1. Accept dream2nix as optional jackpkgs input
2. Add `fromLockfile` option for automatic node_modules building
3. Handle common native dependency overrides

**Deliverable:** Zero-config TypeScript checks for simple projects

### Phase 4: Testing and Hardening

1. Add integration tests with various pnpm workspace structures
2. Test with real-world Pulumi projects
3. Document known issues and workarounds

**Deliverable:** Production-ready TypeScript checks

---

## Example: Complete Consumer Integration

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
    dream2nix.url = "github:nix-community/dream2nix";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.jackpkgs.flakeModules.default
        ./nix/flake-module.nix
      ];
      systems = ["x86_64-linux" "aarch64-darwin"];
    };
}
```

```nix
# nix/flake-module.nix
{ inputs, ... }: {
  perSystem = { pkgs, system, ... }: let
    # Configure dream2nix for this project
    dreamPkgs = inputs.dream2nix.lib.makeFlakeOutputs {
      systems = [system];
      config.projectRoot = ../.;
      source = ../.;
      projects.default = {
        name = "my-pulumi-project";
        relPath = "";
        subsystem = "nodejs";
        translator = "pnpm-lock";
      };
    };
  in {
    # Enable TypeScript checks with dream2nix-built node_modules
    jackpkgs.checks.typescript = {
      enable = true;
      tsc = {
        packages = ["infra" "tools/scripts"];
        nodeModules = dreamPkgs.packages.${system}.default.lib.node_modules;
      };
    };
  };
}
```

---

## Design Question: Binary Exposure Strategy

### Problem

The current `nodejs.nix` devshell uses `PATH="$PWD/node_modules/.bin:$PATH"` in shellHook, which:
1. Relies on runtime filesystem state (impure `pnpm install`)
2. Differs from how Python (uv2nix) exposes binaries

Compare with Python:
```nix
# Python (uv2nix) - Pure Nix approach
export PATH="${editableEnv}/bin:$PATH"  # Nix store path
```

```nix
# Node.js (current) - Impure approach
export PATH="$PWD/node_modules/.bin:$PATH"  # Filesystem path
```

### Recommended Solution

When `nodeModules` is available from dream2nix, use the Nix store path in shellHook.

**Important:** You cannot use `builtins.pathExists` to check the structure at Nix evaluation
time because the derivation hasn't been built yet (store path doesn't exist). The path
existence checks must happen at runtime (when shellHook executes or when check scripts run).

```nix
shellHook = lib.optionalString (nodeModules != null) ''
  # Use dream2nix-built binaries from Nix store (pure, preferred)
  # Check at runtime which structure dream2nix used (can't check at eval time!)
  if [ -d "${nodeModules}/lib/node_modules/.bin" ]; then
    export PATH="${nodeModules}/lib/node_modules/.bin:$PATH"
  elif [ -d "${nodeModules}/node_modules/.bin" ]; then
    export PATH="${nodeModules}/node_modules/.bin:$PATH"
  fi
'' + ''
  # Fallback for impure builds (pnpm install)
  export PATH="$PWD/node_modules/.bin:$PATH"
'';
```

The key insight: we can **construct** the Nix store path at evaluation time (string interpolation),
but we must **check if it exists** at runtime (in shell scripts).

### Future Enhancement: Node.js Bin Environment

For full parity with Python, create a wrapper derivation that exposes binaries in `$out/bin/`:

```nix
# Similar to pythonEditableHook pattern
nodeBinEnv = pkgs.runCommand "node-bin-env" {} ''
  mkdir -p $out/bin
  for bin in ${nodeModules}/lib/node_modules/.bin/*; do
    name="$(basename "$bin")"
    # Create wrapper that ensures node is available
    cat > "$out/bin/$name" << EOF
#!/usr/bin/env bash
exec ${lib.getExe nodejsPackage} "$bin" "\$@"
EOF
    chmod +x "$out/bin/$name"
  done
'';

# Then in devshell:
packages = [ nodeBinEnv ];  # No shellHook PATH manipulation needed
```

This would:
1. Make binaries proper Nix derivations
2. Allow `nix run .#jest` style invocations
3. Match the uv2nix pattern exactly
4. Work in CI without PATH manipulation

### Trade-offs

| Approach | Purity | Simplicity | Compatibility |
|----------|--------|------------|---------------|
| Current (`$PWD/node_modules/.bin`) | Low | High | Works with impure pnpm install |
| Nix store path in shellHook | Medium | High | Requires dream2nix |
| Bin wrapper derivation | High | Medium | Requires dream2nix |

**Recommendation:** Implement the shellHook Nix store path approach now (medium complexity, medium purity), with the bin wrapper as a future enhancement for full parity.

---

## Related

- **ADR-016: CI Checks Module** - Parent design for checks infrastructure
- **ADR-013: CI DevShells** - Related pattern for minimal CI environments
- **dream2nix documentation** - https://nix-community.github.io/dream2nix/
- **pnpm workspace docs** - https://pnpm.io/workspaces
- **Issue** - jackpkgs PR discussing this problem

---

Author: Claude
Date: 2026-01-25
PR: (pending)
