# TypeScript-First ESM on Node 24

**Date**: 2026-04-03
**Status**: Investigation complete, pending execution
**Context**: jackpkgs PR #213, toolbox PR #125

## Problem

Every TypeScript project requires a build/compile step (`tsc` emit, esbuild, etc.) before code can run. This causes:

- Nix sandbox builds need `buildPhase` with tsc or a bundler
- GitHub tarball installs of internal packages (e.g., `@jmmaloney4/sector7`) ship without `dist/`, breaking consumers
- New machines need build tooling "permitted" and bootstrapped before things work
- Fragile, janky developer experience -- TypeScript is supposed to be the source of truth but we spend time managing its compilation artifacts

## Solution: Native TypeScript on Node 24

Run `.ts` files directly in the Node 24 runtime. No compilation step. TypeScript is the source of truth at every stage -- authoring, type checking, and runtime.

### Why Node 24 (not Bun/Deno)

- **Stability**: Node is the standard runtime. Pulumi, wrangler, esbuild, Vite all test against Node first.
- **Type stripping is de facto stable**: Enabled by default since Node 23.6 (early 2025). Uses SWC-based Amaro loader. Ships across two major versions. The `--experimental-` label is conservative but the feature is mature.
- **No new runtime dependency**: All three org repos (garden, zeus, yard) already use Node via Nix. No ecosystem change.
- **Standardization**: Node + ESM + TypeScript is the convergent industry direction.

### What Node 24 Type Stripping Supports

- Erasable TypeScript syntax only: type annotations, interfaces, type aliases, generics
- Runs `.ts` files directly: `node src/index.ts` just works
- **No flag needed** in Node 24 -- enabled by default

### What It Does NOT Support (and we accept)

- **Enums** -- use string union types instead (`type Status = "active" | "inactive"`)
- **Namespaces** -- use ES modules instead
- **Parameter properties** (`constructor(public x: number)`) -- assign in constructor body
- **JSX** -- use Vite/esbuild for frontend bundles (already the case)
- **`import X = require(...)`** -- use ESM imports

None of our repos use these patterns. Acceptable constraint enforced by `erasableSyntaxOnly` in tsconfig.

### Import Extensions

Node's native TS loader requires `.ts` extensions in relative imports:

```ts
// YES -- Node native TS
import { foo } from "./bar.ts"

// NO -- old convention (fails when only bar.ts exists)
import { foo } from "./bar.js"
```

Current repos all use `.js` extensions. This requires a one-time mechanical rename across all `.ts` source files. TypeScript 5.8 `allowImportingTsExtensions` makes tsc accept `.ts` in imports (requires `noEmit: true`, which we want anyway).

## Target tsconfig

Every package in every repo:

```json
{
  "compilerOptions": {
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "allowImportingTsExtensions": true,
    "erasableSyntaxOnly": true,
    "verbatimModuleSyntax": true,
    "target": "ES2022",
    "strict": true
  }
}
```

- `noEmit: true` -- tsc is for type checking only, never produces output
- `allowImportingTsExtensions: true` -- permits `.ts` in import paths
- `erasableSyntaxOnly: true` -- enforces no enums/namespaces/etc at type-check time
- `verbatimModuleSyntax: true` -- enforces ESM purity (no CJS interop)

## Migration Plan

### Per-Repo Steps

1. **tsconfig update** to the target config above
2. **Bulk import rename**: `./foo.js` -> `./foo.ts` in all relative imports across `.ts` files
3. **package.json updates**:
   - `"type": "module"` in every package (already the case in sub-packages)
   - `"engines": { "node": ">=24.0.0" }` in root package.json
   - Remove `build`, `compile`, `prepare` scripts that run tsc/esbuild
   - Point `types` and `default` exports at `.ts` source files (not `dist/`)
   - Remove `dist/` from `files` array
4. **Nix simplification**: remove `buildPhase` from derivations, install source + node_modules only
5. **Validate**: `nix flake check` passes (tsc --noEmit still runs as a check)

### Internal Packages (sector7)

toolbox PR #125 exposed the core issue: `@jmmaloney4/sector7` can't resolve types when installed via GitHub tarball because `dist/` doesn't exist in the repo. The current PR points `types` at `.ts` source as a patch.

Full fix: convert sector7 to `"type": "module"`, point all exports at source, require Node 24. No build step, no `dist/`, no `prepare` script.

### Execution Order

1. **jackpkgs** -- already done: nodejs module uses derivation options, default is nodejs_24 (PR #213)
2. **zeus** -- already on Node 24, `engines: ">=24.0.0"`, `verbatimModuleSyntax: true`. Only needs import rename.
3. **garden** -- already on nodejs_24 via Nix overlay. Needs import rename + sector7 update.
4. **yard** -- needs `@types/node` bump (^20 -> ^24), `engines` field, `verbatimModuleSyntax`, and import rename.

## Consumer Readiness (from analysis)

| Repo | Node 24 | `type: "module"` | NodeNext | verbatimModuleSyntax | .js imports | Status |
|------|---------|------------------|----------|---------------------|-------------|--------|
| garden | nodejs_24 via Nix | all workspaces | all workspaces | no | .js in all .ts files | Import rename needed |
| zeus | >=24.0.0 (explicit) | all 11 packages | all 11 packages | yes | .js in all .ts files | Import rename only |
| yard | not constrained | all 12 packages | all 12 packages | no | .js in all .ts files | Types bump + import rename |

## Risks

- **Experimental label**: Node still labels type stripping as "experimental". In practice it's been the default for 15+ months across two major versions. Low risk of removal or breaking change.
- **Erasable-only constraint**: If a future dependency or pattern requires enums or namespaces, we'd need `--experimental-transform-types` or a build step for that file. Acceptable given our current codebase.
- **npm publishing**: Packages published to npm would ship `.ts` source. Consumers would need Node 24+ or a bundler that handles `.ts`. For internal packages (sector7) installed via GitHub tarball, this is fine. For any public packages, we'd need to reconsider.
- **Pulumi compatibility**: Pulumi's Node SDK is tested against Node. It works with type stripping because Pulumi doesn't use `.ts` imports at runtime. No issue expected.
