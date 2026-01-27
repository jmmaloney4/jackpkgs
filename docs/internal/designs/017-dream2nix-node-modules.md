# ADR-017: dream2nix for Pure Node.js Dependency Management

## Status

In Progress (Phase 1)

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
  setupCommands = ''
    # Copy source to writeable directory
    cp -R ${lib.escapeShellArg projectRoot} src
    chmod -R +w src
    cd src

    # Link node_modules from the provided derivation
    # This handles both root-level and per-package node_modules
    ${linkNodeModules cfg.typescript.tsc.nodeModules tsPackages}
  '';
  checkCommands =
    lib.concatMapStringsSep "\n" (pkg: ''
      echo "Type-checking ${pkg}..."
      cd ${lib.escapeShellArg pkg}
      tsc --noEmit ${lib.escapeShellArgs cfg.typescript.tsc.extraArgs}
    '')
    tsPackages;
};
```

#### Node Modules Linking Strategy

For pnpm workspaces, `node_modules` structure varies:

1. **Hoisted dependencies** - Shared dependencies at workspace root
2. **Per-package node_modules** - Package-specific dependencies with symlinks

The linking function must handle both, and also detect which output structure dream2nix used:

```nix
# Helper to link node_modules into the sandbox (from checks.nix)
linkNodeModules = nodeModules: packages:
  if nodeModules == null
  then ""
  else ''
    nm_store=${lib.escapeShellArg nodeModules}
    echo "Linking node_modules from $nm_store..."

    # Detect dream2nix output structure (lib/node_modules vs node_modules)
    if [ -d "$nm_store/lib/node_modules" ]; then
       nm_root="$nm_store/lib/node_modules"
    elif [ -d "$nm_store/node_modules" ]; then
       nm_root="$nm_store/node_modules"
    else
       echo "WARNING: Could not find node_modules in provided derivation: $nm_store"
       nm_root=""
    fi

    if [ -n "$nm_root" ]; then
      # Link root node_modules
      ln -sfn "$nm_root" node_modules

      # Link package-level node_modules
      ${lib.concatMapStringsSep "\n" (pkg: ''
        pkg_dir=${lib.escapeShellArg pkg}
        mkdir -p "$pkg_dir"

        # Check for nested node_modules in the store output
        # pnpm workspaces often have nested node_modules for each package
        if [ -d "$nm_root/$pkg_dir/node_modules" ]; then
          ln -sfn "$nm_root/$pkg_dir/node_modules" "$pkg_dir/node_modules"
        fi
      '') packages}
    fi
  '';
```

See **Appendix B** for a detailed explanation of what lives where (including an open question about path depth).

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
2. Allow `nix run .#vitest` style invocations
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

- **ADR-005: uv2nix Editable vs Non-Editable Environments** - Python's approach to editable installs (contrast with Appendix A)
- **ADR-016: CI Checks Module** - Parent design for checks infrastructure
- **ADR-013: CI DevShells** - Related pattern for minimal CI environments
- **dream2nix documentation** - https://nix-community.github.io/dream2nix/
- **pnpm workspace docs** - https://pnpm.io/workspaces

---

## Appendix A: Why Node.js Doesn't Need "Editable Environments"

### Python's Editable Mode (uv2nix)

Python has two distinct environment modes (see ADR-005):

| Mode | Use Case | Where Code Lives |
|------|----------|------------------|
| **Non-editable** | CI, packages | All code baked into Nix store derivation |
| **Editable** | Developer shells | Workspace packages path-installed; changes reflect immediately |

The editable overlay in uv2nix performs `pip install -e .` style installs — your local `.py` files are imported directly, not copied to the store. This is crucial because:

- Python imports modules by file path at runtime
- Developers need instant feedback when editing code
- Without editable mode, you'd rebuild the Nix derivation on every code change

### Node.js: Always "Editable" by Design

Node.js doesn't need this distinction because of fundamental differences in how the ecosystem works:

**1. Dependencies ≠ Your Code**

`node_modules` contains *only third-party dependencies*, not your workspace code. Your TypeScript/JavaScript source files are never "installed" into `node_modules`.

**2. Import Resolution**

Node/TypeScript resolves imports differently based on the path:

```typescript
// Resolved from YOUR source files (working directory)
import { foo } from "./src/utils";
import { bar } from "../shared/types";

// Resolved from node_modules (Nix store via symlink)
import _ from "lodash";
import * as aws from "@pulumi/aws";
```

**3. No "Installation" of Your Own Code**

Unlike Python's `pip install -e .`, there's no step where your workspace packages get installed. Tools read your source files directly from disk.

### Comparison Table

| Aspect | Python | Node.js |
|--------|--------|---------|
| Your code location | Installed into env (editable or not) | Always read from working directory |
| Third-party deps | In Nix store (via uv2nix) | In Nix store (via dream2nix) |
| "Editable" concept | Required for dev workflow | Not applicable |
| Mode switching | Yes (editable vs non-editable) | No (single mode) |

### The Node.js Analogy

| Python editable | Node.js equivalent |
|-----------------|-------------------|
| Workspace packages path-installed, editable | Your source files are *always* read from disk |
| Third-party deps from Nix store | `node_modules` symlinked from Nix store |

**Conclusion:** Node.js is effectively always "editable" for your own code and always "non-editable" for dependencies. There's no mode switch needed.

---

## Appendix B: What Lives Where (Linking Strategy Deep Dive)

> **Note:** The dream2nix output structure was verified in Appendix C. The structure is
> `<store>/lib/node_modules/.bin` for binaries and `<store>/lib/node_modules/<pkg>/node_modules`
> for package-level dependencies. There is **no** extra `node_modules` level at root.
> The implementation and documentation now reflect this verified structure.

### Overview Diagram

```
┌────────────────────────────────────────────────────────────────┐
│                     Your Working Directory                      │
├────────────────────────────────────────────────────────────────┤
│  src/                    ← Your code (always editable)          │
│  packages/foo/           ← Your workspace packages              │
│  packages/foo/src/       ← Package source (read from disk)      │
│                                                                  │
│  node_modules/ → symlink ─────────────────────────┐             │
│  packages/foo/node_modules/ → symlink ────────────┤             │
└────────────────────────────────────────────────────│────────────┘
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────┐
│                         Nix Store                               │
├────────────────────────────────────────────────────────────────┤
│  /nix/store/xxx-node_modules/                                   │
│    lib/node_modules/                                            │
│      .bin/                                                      │
│        vitest → ../vitest/bin/vitest.mjs                               │
│        tsc → ../typescript/bin/tsc                              │
│        eslint → ../eslint/bin/eslint.js                         │
│      lodash/                                                    │
│      typescript/                                                │
│      @types/node/                                               │
│      packages/foo/node_modules/  ← Per-package deps             │
│        some-local-dep/                                          │
└────────────────────────────────────────────────────────────────┘
```

### Location Summary

| Location | Contents | Mutable? | Source |
|----------|----------|----------|--------|
| **Nix Store** | `node_modules` derivation (all deps + binaries) | No (immutable) | Built by dream2nix from `pnpm-lock.yaml` |
| **Working Directory** | Symlinks to Nix store paths | Yes (recreated) | Created at runtime by `linkNodeModules` |
| **Working Directory** | Your source code | Yes (editable) | Your files, read directly by tools |
| **Local (impure)** | `node_modules/` from `pnpm install` | Yes | Only for devs without dream2nix configured |

### How Binaries Get on $PATH

**In DevShells (`nodejs.nix`):**

```bash
# Priority 1: Pure Nix store path (if dream2nix configured)
if [ -d "${nodeModules}/lib/node_modules/.bin" ]; then
  export PATH="${nodeModules}/lib/node_modules/.bin:$PATH"
fi

# Priority 2: Fallback for impure builds
export PATH="$PWD/node_modules/.bin:$PATH"
```

**In CI Checks (`checks.nix`):**

- `linkNodeModules` creates `node_modules` symlink → Nix store
- Shell's PATH includes linked `node_modules/.bin`
- `command -v vitest` finds binary from trusted Nix store path

### Key Insight: Symlinks Enable Purity

The linking strategy provides the best of both worlds:

1. **Dependencies are immutable** — stored in Nix store, content-addressed, cacheable
2. **Tools work normally** — they see `node_modules` in the expected location
3. **No file copying** — symlinks are cheap and instant
4. **Source stays editable** — your code is never copied to the store

This is why Node.js doesn't need Python's complex editable/non-editable distinction: the symlink-based approach inherently separates "your code" (mutable, in working directory) from "dependencies" (immutable, in Nix store).

---

## Appendix C: dream2nix Layout Investigation (pnpm2nix module)

This appendix documents the dream2nix source investigation performed against the exact
revision pinned in this repository's `flake.lock`:

- `dream2nix` rev: `69eb01fa0995e1e90add49d8ca5bcba213b0416f`

At this revision, the Node.js module used by the `pnpm-lock` translator is
`nodejs-granular` (the same module used by `nodejs-package-lock`). The layout for the
`node_modules` derivation is determined by this module, not by the translator itself.

### Evidence from dream2nix source

- `modules/dream2nix/nodejs-granular/installPhase.nix` copies the build's
  `$nodeModules` into `$out/lib/node_modules` and then sets `nodeModules=$out/lib/node_modules`.
- `modules/dream2nix/nodejs-granular/configurePhase.nix` uses `$nodeModules/.bin` and
  sets `NODE_PATH="$nodeModules/$packageName/node_modules"`.
- `modules/dream2nix/nodejs-granular/devShell.nix` references:
  - `nodeModulesDir = $out/lib/node_modules/${packageName}/node_modules`
  - `binDir = $out/lib/node_modules/.bin`

### Resulting layout

```
<store>/lib/node_modules/.bin
<store>/lib/node_modules/<packageName>/node_modules
```

### Implications for this ADR and open issues

- The layout above **does not** contain an extra `node_modules` level at the root
  (i.e., `<store>/lib/node_modules/node_modules` is not expected).
- This supports keeping the `.bin` lookup at `.../lib/node_modules/.bin`.
- If we want to link a workspace root `node_modules`, it should likely point at the
  root package's `node_modules` (e.g., `<store>/lib/node_modules/<rootPackageName>/node_modules`),
  not at `<store>/lib/node_modules/node_modules`.

---

Author: Claude
Date: 2026-01-25
PR: #119
