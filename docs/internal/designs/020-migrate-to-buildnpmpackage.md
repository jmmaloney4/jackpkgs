# ADR-020: Migrate from dream2nix to buildNpmPackage

## Status

Proposed

## Context

### Current State

`jackpkgs.nodejs` module currently uses `dream2nix` to build `node_modules` as a Nix derivation:

```nix
dreamOutputs = jackpkgsInputs.dream2nix.lib.makeFlakeOutputs {
  config.projectRoot = cfg.projectRoot;
  source = cfg.projectRoot;
  projects = {
    default = {
      subsystem = "nodejs";
      translator = "package-lock";
      subsystemInfo.nodejs = cfg.version;
    };
  };
};
```

**Current dream2nix usage:**
- Outputs node_modules at: `packages.${system}.default.lib.node_modules`
- Structure: `<store>/lib/node_modules/default/node_modules/<dependency>` (nested)
- Requires dream2nix as external input
- Requires complex `linkNodeModules` logic in checks.nix to handle nested structure

### Problem

1. **External dependency**: dream2nix must be added to consumer flake inputs and managed separately
2. **API instability**: dream2nix is actively evolving; breaking changes require jackpkgs updates
3. **Overkill for npm**: dream2nix is designed for multiple package managers (pnpm, yarn, npm), but jackpkgs only uses npm since ADR-019
4. **Complexity**: Nested node_modules structure requires complex linking logic in checks.nix

### Constraints

- Must maintain `jackpkgs.outputs.nodeModules` API for compatibility with checks module
- Must support npm workspaces (package.json `workspaces` field)
- Must work in pure Nix sandbox (no network access)
- Workspace discovery should remain in checks.nix (or move to shared helper in future)
- Should require per-package `.bin` directory support in devshell

### Related Work

- **ADR-019**: Migrate from pnpm to npm — Switched to `package-lock.json`, which dream2nix's legacy API supports
- **ADR-017**: dream2nix for Pure Node.js Dependency Management — Established dream2nix integration pattern
- **ADR-016**: CI Checks Module — Depends on `nodeModules` derivation for TypeScript/Vitest checks

## Decision

We will migrate from dream2nix to `buildNpmPackage` (nixpkgs native) with a **single derivation at workspace root** approach.

### Core Design

Use `pkgs.buildNpmPackage` to build entire npm workspace as a single derivation:

```nix
nodeModules = pkgs.buildNpmPackage {
  name = "node-modules";
  src = cfg.projectRoot;
  npmDeps = pkgs.importNpmLock {
    npmRoot = cfg.projectRoot;
    packageLock = cfg.projectRoot + "/package-lock.json";
  };
  installPhase = ''
    cp -R node_modules $out
  '';
};
```

### Key Differences from dream2nix

| Aspect | dream2nix | buildNpmPackage |
|--------|-------------|-----------------|
| **Dependency** | External input | Built into nixpkgs |
| **Output structure** | Nested: `<store>/lib/node_modules/default/node_modules/` | Flat: `<store>/node_modules/` |
| **Workspace handling** | Per-package derivations (granular) | Single derivation with workspace hoisting |
| **Caching** | Granular (per package) | Coarse (all deps in one derivation) |
| **API** | Custom `makeFlakeOutputs` | Standard nixpkgs API |

### Why Single Derivation?

npm's workspace mechanism hoists dependencies to the root `node_modules` by default. This means:
- All dependencies are accessible from any workspace package
- `import 'my-lib'` works regardless of which package you're in
- Matches how developers run `npm install` naturally

Single derivation is sufficient for 90% of use cases. If package isolation becomes problematic, we can migrate to per-package derivations (future work).

### Implementation Scope

**In scope:**
- Replace dream2nix with buildNpmPackage in `nodejs.nix`
- Remove dream2nix from jackpkgs inputs
- Update checks.nix `linkNodeModules` to handle flat structure
- Update devshell binary path detection

**Out of scope:**
- Per-package derivations (defer to future if needed)
- Shared workspace discovery helper (keep in checks.nix for now)
- Support for pnpm/yarn (we're npm-only per ADR-019)

## Consequences

### Benefits

1. **Simpler dependency graph** — No external dream2nix input needed
2. **Native nixpkgs API** — Uses well-maintained `buildNpmPackage`
3. **Faster for simple projects** — Single derivation vs multiple granular builds
4. **Easier to maintain** — Less custom code, standard patterns
5. **Better UX** — Matches developers' mental model of `npm install`

### Trade-offs

1. **Coarser caching** — Changing one dependency invalidates entire `node_modules` hash
   - Mitigation: Acceptable tradeoff for simplicity; can upgrade to granular later if needed
2. **No per-package isolation** — All packages share hoisted dependencies
   - Mitigation: npm workspaces designed for this; rarely causes issues
3. **Binary path complexity** — Need to support both nested and flat structures during transition
   - Mitigation: Runtime detection in devshell and checks.nix

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Workspace hoisting issues | Low | Medium | npm standard; test with complex monorepos |
| Binary path detection bugs | Medium | Medium | Add fallback logic; test thoroughly |
| Breaking changes for consumers | Low | High | API remains same (`nodeModules` output) |
| Build time regression | Low | Low | Single derivation often faster than multiple granular |

## Alternatives Considered

### Alternative A — Keep dream2nix

**Approach:** Maintain status quo with dream2nix.

**Pros:**
- Already works
- Granular caching
- Per-package isolation

**Cons:**
- External dependency
- API instability
- Overkill for npm-only

**Why not chosen:** ADR-019 made us npm-only; dream2nix is unnecessary complexity

### Alternative B — Per-Package buildNpmPackage Derivations

**Approach:** Build each workspace member independently.

```nix
nodeModules = pkgs.symlinkJoin {
  name = "node-modules";
  paths = lib.mapAttrsToList (name: drv: drv) (
    lib.mapAttrs (name: _:
      pkgs.buildNpmPackage {
        name = "node-modules-${name}";
        src = cfg.projectRoot + "/${name}";
        npmDeps = pkgs.importNpmLock {
          npmRoot = cfg.projectRoot + "/${name}";
          packageLock = cfg.projectRoot + "/${name}/package-lock.json";
        };
        installPhase = ''
          mkdir -p $out/${name}
          cp -R node_modules $out/${name}
        '';
      }
    ) workspacePackages
  );
};
```

**Pros:**
- Per-package isolation
- Closer to dream2nix behavior
- Better for complex monorepos with conflicting deps

**Cons:**
- Multiple derivations (slower builds)
- More complex implementation (~50-80 lines)
- Requires workspace discovery in nodejs.nix

**Why not chosen:** Single derivation is sufficient for standard npm workspaces; can upgrade later if needed

### Alternative C — napalm

**Approach:** Use napalm for granular dependency caching.

**Pros:**
- Best cache granularity
- Good for monorepos

**Cons:**
- Harder to configure for C++ dependencies
- Less mature than buildNpmPackage
- Another external dependency

**Why not chosen:** buildNpmPackage is simpler and built into nixpkgs

## Implementation Plan

### Phase 1: Update nodejs.nix

1. **Remove dream2nix dependency:**
   - Delete `jackpkgsInputs.dream2nix` from module signature
   - Remove `dreamOutputs` computation

2. **Replace with buildNpmPackage:**
   ```nix
   nodeModules = pkgs.buildNpmPackage {
     name = "node-modules";
     src = cfg.projectRoot;
     npmDeps = pkgs.importNpmLock {
       npmRoot = cfg.projectRoot;
       packageLock = cfg.projectRoot + "/package-lock.json";
     };
     installPhase = ''
       cp -R node_modules $out
     '';
   };
   ```

3. **Update devshell `.bin` detection:**
   ```nix
   shellHook = ''
     node_modules_bin=""
     
     # buildNpmPackage flat structure
     if [ -d "${nodeModules}/node_modules/.bin" ]; then
       node_modules_bin="${nodeModules}/node_modules/.bin"
     # dream2nix nested structure (for backwards compatibility)
     elif [ -d "${nodeModules}/lib/node_modules/.bin" ]; then
       node_modules_bin="${nodeModules}/lib/node_modules/.bin"
     # dream2nix nodejs-granular nested (deep)
     elif [ -d "${nodeModules}/lib/node_modules/default/node_modules/.bin" ]; then
       node_modules_bin="${nodeModules}/lib/node_modules/default/node_modules/.bin"
     fi
     
     if [ -n "$node_modules_bin" ]; then
       export PATH="$node_modules_bin:$PATH"
     else
       export PATH="$PWD/node_modules/.bin:$PATH"
     fi
   '';
   ```

4. **Update option description:**
   - Change "via dream2nix" to "via buildNpmPackage"

### Phase 2: Update checks.nix

1. **Update `linkNodeModules` for flat structure:**
   ```nix
   linkNodeModules = nodeModules: packages:
     if nodeModules == null
     then ""
     else ''
       nm_store=${nodeModules}
       echo "Linking node_modules from $nm_store..."
       
       # Detect buildNpmPackage vs dream2nix structure
       if [ -d "$nm_store/node_modules" ]; then
         # buildNpmPackage flat structure
         nm_root="$nm_store/node_modules"
       elif [ -d "$nm_store/lib/node_modules/default/node_modules" ]; then
         # dream2nix nested structure (nodejs-granular)
         nm_root="$nm_store/lib/node_modules/default/node_modules"
       elif [ -d "$nm_store/lib/node_modules" ]; then
         # dream2nix nested structure (nodejs-npm-wrapper)
         nm_root="$nm_store/lib/node_modules"
       else
         echo "ERROR: Unknown node_modules structure" >&2
         exit 1
       fi
       
       # Link root node_modules
       ln -sfn "$nm_root" node_modules
       
       # For buildNpmPackage flat structure, packages find deps via hoisting
       # No per-package node_modules linking needed
       # (dream2nix needed per-package linking due to nested structure)
     '';
   ```

2. **Update error messages:**
   - Change "dream2nix" to "buildNpmPackage"
   - Remove ADR-017 reference (superseded)

3. **Update binary PATH in Vitest checks:**
   ```nix
   ${lib.optionalString (vitestNodeModules != null) ''
     # buildNpmPackage flat structure
     if [ -d "${vitestNodeModules}/node_modules/.bin" ]; then
       export PATH="${vitestNodeModules}/node_modules/.bin:$PATH"
     # dream2nix nested structure
     elif [ -d "${vitestNodeModules}/lib/node_modules/.bin" ]; then
       export PATH="${vitestNodeModules}/lib/node_modules/.bin:$PATH"
     # dream2nix nodejs-granular (deep)
     elif [ -d "${vitestNodeModules}/lib/node_modules/default/node_modules/.bin" ]; then
       export PATH="${vitestNodeModules}/lib/node_modules/default/node_modules/.bin:$PATH"
     fi
   ''}
   ```

### Phase 3: Remove dream2nix Input

1. **Update `all.nix`:**
   - Remove dream2nix from `inputs`
   - Remove dream2nix from `imports`

2. **Update flake.nix (jackpkgs):**
   - Remove dream2nix from `inputs`

### Phase 4: Documentation

1. **Update README:**
   - Remove dream2nix mentions
   - Add buildNpmPackage note (built into nixpkgs)
   - Update nodejs module example

2. **Update ADR-019:**
   - Add reference to this ADR in "Alternatives Considered"
   - Note that this supersedes the dream2nix approach

3. **Create migration guide (if needed):**
   - Document transition path for consumers
   - Note that API is unchanged (`jackpkgs.outputs.nodeModules`)

### Phase 5: Testing

1. **Test simple npm project:**
   - Verify node_modules derivation builds
   - Verify devshell PATH works
   - Verify TypeScript checks work

2. **Test npm workspace monorepo:**
   - Verify workspace hoisting works
   - Verify imports resolve correctly
   - Verify tsc and vitest checks work

3. **Test backwards compatibility:**
   - Verify checks.nix still works if consumer provides custom nodeModules
   - Verify error messages are helpful

## Migration & Rollout

- **Breaking change:** No breaking changes to consumer API
- **Internal change:** Implementation detail only
- **Migration required:** None for consumers
- **Rollback:** If issues discovered, revert to dream2nix commit

## Related

- **ADR-019**: Migrate from pnpm to npm — Supersedes dream2nix justification
- **ADR-017**: dream2nix for Pure Node.js Dependency Management — Superseded by this ADR
- **ADR-016**: CI Checks Module — Depends on nodeModules output
- **PR**: TBD
- **Issue**: TBD

---

Author: Claude (Cursor)
Date: 2026-01-30
Status: Proposed
