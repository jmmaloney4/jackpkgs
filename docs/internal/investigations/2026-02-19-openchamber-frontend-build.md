# OpenChamber Frontend Build Investigation

**Date**: 2025-02-19
**Status**: In Progress
**Package**: `pkgs/openchamber`

## Summary

The OpenChamber Nix package runs but serves no web UI because the frontend build step (`vite build`) is never executed. This document covers the investigation into both the slow `fixupPhase` and the missing frontend build.

---

## Part 1: Slow fixupPhase (17+ minutes)

### Observation

```
openchamber> fixupPhase completed in 17 minutes 16 seconds
```

### Root Cause

The derivation copies the entire `node_modules` tree (including Bun's `.bun` store with 1400+ packages) into `$out` using `cp -rL` which dereferences symlinks. This creates a massive file count that `fixupPhase` must walk recursively for:

- Shebang patching
- Reference scanning
- Binary stripping
- Native library handling

Native dependencies like `node-pty`, `sharp`/`vips` add additional overhead.

### Mitigation Options (Not Yet Implemented)

1. Reduce what gets copied to `$out`
2. Disable parts of fixup (`dontStrip`, `dontFixup`) if runtime permits
3. Use a leaner dependency tree

---

## Part 2: Module Resolution Bug (Fixed)

### Observation

```
Error executing command 'serve': Cannot find module 'body-parser'
Require stack:
- /nix/store/.../lib/node_modules/express/lib/express.js
```

### Root Cause

Bun stores transitive dependencies under `.bun/node_modules/` and creates symlinks at the top-level `node_modules/` for Node's resolution. When we run `cp -rL node_modules/. $out/lib/node_modules/`, the dereferenced copy loses these top-level symlinks.

Result: `express` does `require('body-parser')` but `body-parser` only exists at `node_modules/.bun/node_modules/body-parser/`, not `node_modules/body-parser/`.

### Fix Applied

Added to `installPhase` in `pkgs/openchamber/default.nix`:

```bash
# Bun keeps many transitive deps under .bun/node_modules and relies on
# links from the top-level node_modules for Node resolution.
# Recreate any missing top-level links so runtime requires work.
if [ -d "$out/lib/node_modules/.bun/node_modules" ]; then
  for dep in "$out/lib/node_modules/.bun/node_modules"/*; do
    name="$(basename "$dep")"
    if [ ! -e "$out/lib/node_modules/$name" ]; then
      ln -s ".bun/node_modules/$name" "$out/lib/node_modules/$name"
    fi
  done
fi
```

### Commit

```
fix(openchamber): add symlinks for .bun deps to fix module resolution
```

---

## Part 3: Missing Frontend Build (Current Issue)

### Observation

Server starts successfully but web UI fails:

```
Warning: /nix/store/.../lib/node_modules/@openchamber/web/dist not found, static files will not be served
```

At `localhost:3000`:

```
Static files not found. Please build the application first.
```

### Root Cause

The derivation copies raw source but never runs `vite build`:

```nix
# Current installPhase - just copies source, no build
cp -r packages/web $out/lib/node_modules/@openchamber/web
cp -rL node_modules/. $out/lib/node_modules/
```

### Framework & Build System

- **Framework**: React 19 with TypeScript
- **Bundler**: Vite 7 with `@vitejs/plugin-react`
- **Styling**: Tailwind CSS 4
- **UI Components**: Radix UI
- **State**: Zustand
- **PWA**: `vite-plugin-pwa` with service worker

### Build Configuration Files

Located in `packages/web/`:

| File | Purpose |
|------|---------|
| `vite.config.ts` | Main build config, output to `dist/` |
| `tsconfig.json` | TypeScript config (noEmit, type-check only) |
| `index.html` | Vite HTML entry point |

### Server Static File Resolution

From `server/index.js`:

```js
const distPath = (() => {
  const env = typeof process.env.OPENCHAMBER_DIST_DIR === 'string' 
    ? process.env.OPENCHAMBER_DIST_DIR.trim() : '';
  if (env) {
    return path.resolve(env);
  }
  return path.join(__dirname, '..', 'dist');
})();
```

- Default: `<web-package-root>/dist/`
- Override: `OPENCHAMBER_DIST_DIR` environment variable

### Monorepo Build Dependencies

The Vite build requires access to sibling packages and root-level files. From `vite.config.ts`:

```ts
resolve: {
  alias: [
    { find: '@opencode-ai/sdk/v2', replacement: path.resolve(__dirname, '../../node_modules/@opencode-ai/sdk/dist/v2/client.js') },
    { find: '@openchamber/ui', replacement: path.resolve(__dirname, '../ui/src') },
    { find: '@web', replacement: path.resolve(__dirname, './src') },
    { find: '@', replacement: path.resolve(__dirname, '../ui/src') },
  ],
},
```

And plugin import:

```ts
import { themeStoragePlugin } from '../../vite-theme-plugin';
```

**Required paths (relative to `packages/web`):**

| Path | Purpose |
|------|---------|
| `../../node_modules/` | Root workspace deps, esp. `@opencode-ai/sdk` |
| `../ui/src/` | `@openchamber/ui` package (compiled inline by Vite) |
| `../../vite-theme-plugin.ts` | Vite plugin (no-op stub, must be resolvable) |

**Important**: `packages/ui` has no build output (`tsc --noEmit` only). Vite compiles its `.tsx` sources directly.

### Build Script

From `packages/web/package.json`:

```json
{
  "scripts": {
    "build": "vite build",
    "build:watch": "vite build --watch"
  }
}
```

### Expected Build Output

After `vite build`, `packages/web/dist/` should contain:

```
dist/
├── index.html           # Processed with hashed asset references
├── assets/
│   ├── *.js             # Chunked: vendor-react-*, vendor-radix-*, etc.
│   ├── *.css            # Tailwind output
│   └── *.woff2          # Fonts
├── sw.js                # Service worker (IIFE format)
├── *.png, *.svg         # Copied from public/
└── site.webmanifest     # PWA manifest
```

---

## Part 4: Proposed Fix

### Changes Needed in `default.nix`

The `buildPhase` of the outer derivation must run the Vite build **from the repo root context** so relative paths resolve correctly.

```nix
buildPhase = ''
  runHook preBuild

  cp -r ${nodeModules} node_modules
  chmod -R u+w node_modules

  # Build the frontend
  export HOME="$TMPDIR/home"
  export NODE_ENV=production
  
  cd packages/web
  node ../../node_modules/.bin/vite build
  cd ../..

  runHook postBuild
'';
```

**Alternative using Bun** (already a build input):

```bash
bun run --cwd packages/web build
```

### Install Phase

The current `installPhase` already copies all of `packages/web`:

```nix
cp -r packages/web $out/lib/node_modules/@openchamber/web
```

Once `dist/` exists from the build, it will be included automatically.

### Environment Variables

| Variable | Phase | Notes |
|----------|-------|-------|
| `NODE_ENV=production` | Build | Recommended for Vite |
| `HOME` | Build | Required for tooling |
| `OPENCHAMBER_DIST_DIR` | Runtime | Optional override; defaults to `<web-root>/dist` |

---

## Remaining Work

1. Implement the Vite build step in `buildPhase`
2. Verify `dist/` is created and included in output
3. Test the full web UI at `localhost:3000`
4. Consider build-time optimizations to reduce `fixupPhase` duration

---

## References

- Upstream: https://github.com/btriapitsyn/openchamber
- Related investigation: `docs/internal/investigations/2026-02-18-openchamber-packaging.md`
- Package definition: `pkgs/openchamber/default.nix`
