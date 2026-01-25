# ADR-017: dream2nix pnpm Support Research

| Status | Draft |
|--------|-------|
| Date | 2026-01-25 |
| Context | [PR #108](https://github.com/jmmaloney4/jackpkgs/pull/108) |

## Problem Statement

The TypeScript checks module fails in pure Nix builds because `node_modules` doesn't exist in the sandbox. The initial proposal was to use dream2nix to build `node_modules` as a Nix derivation, similar to how uv2nix provides Python dependencies.

**Question from PR review:** Does dream2nix support pnpm v9 lockfiles?

## Research Findings

### dream2nix (nix-community/dream2nix)

**Finding: dream2nix does NOT support pnpm lockfiles.**

The current dream2nix (main branch) only supports npm's `package-lock.json` via the `nodejs-package-lock-v3` module. Examining the available modules:

```
nodejs-package-lock-v3    # npm package-lock.json only
nodejs-package-json-v3    # package.json direct
nodejs-node-modules-v3    # node_modules builder
```

The legacy branch also only includes translators for:
- `npm`
- `package-json`
- `package-lock`
- `yarn-lock`

There is no `pnpm-lock` translator in any version of dream2nix.

### pnpm2nix (nix-community/pnpm2nix)

**Finding: Unmaintained, only supports lockfile v5.0 or below.**

From the repository README:
> *Status: Unmaintained, only compatible with lockfile version 5.0 or below (latest is 9.0 at the time of writing)*

pnpm v8+ uses lockfile version 6.0+, and pnpm v9 uses lockfile version 9.0.

### pnpm2nix-nzbr (nzbr/pnpm2nix-nzbr)

**Finding: Active fork, supports v6.0, has open PR for v9.**

This is an actively maintained fork with additional features:
- Currently supports lockfile version 6.0
- **Open PR #40**: "Fix incompability about pnpm lockfile v9" - adds v9 support but **not yet merged**
- Open PR #35: "Add support for pnpm workspaces" - also not merged

The v9 support PR was opened 2024-06-09 and has been approved but not merged.

## Options for Pure Nix TypeScript Checks

### Option 1: Use pnpm2nix-nzbr with v9 Support

Reference the fork with PR #40 applied:

```nix
{
  inputs.pnpm2nix.url = "github:wrvsrx/pnpm2nix-nzbr/adapt-to-v9";
  # ... or wait for PR merge and use main branch
}
```

**Pros:**
- Pure Nix build
- Works with pnpm v9 lockfiles
- Maintains consistency with Python (uv2nix) approach

**Cons:**
- Depends on unmerged PR branch
- pnpm workspaces support also unmerged (PR #35)
- Fork maintenance uncertain

### Option 2: Generate npm package-lock.json

Run `npm install --package-lock-only` to generate `package-lock.json` alongside `pnpm-lock.yaml`, then use dream2nix with npm lockfile.

```nix
{
  inputs.dream2nix.url = "github:nix-community/dream2nix";
}
```

**Pros:**
- Uses well-maintained dream2nix
- Works today

**Cons:**
- Requires maintaining two lockfiles
- Potential for lockfile drift
- May not work perfectly with pnpm workspace features

### Option 3: CI-Only TypeScript Checks

Run TypeScript checks in GitHub Actions instead of Nix flake checks:

```yaml
# .github/workflows/typecheck.yml
jobs:
  typecheck:
    steps:
      - uses: pnpm/action-setup@v2
      - run: pnpm install
      - run: pnpm tsc --noEmit
```

Disable in Nix:
```nix
jackpkgs.checks.typescript.enable = false;
```

**Pros:**
- Works immediately
- No complex Nix integration
- pnpm ecosystem works as designed

**Cons:**
- Inconsistent with Python checks (which use pure Nix)
- Checks not available in local `nix flake check`

### Option 4: IFD (Import From Derivation)

Run `pnpm install` during Nix evaluation to create `node_modules`.

**Pros:**
- Could work with any pnpm version

**Cons:**
- Breaks pure evaluation
- Generally discouraged in the Nix community
- Causes evaluation-time network access

## Recommendation

Given the current state of the pnpm-to-Nix ecosystem:

1. **Short term:** Use **Option 3 (CI-only)** for projects that need working checks now

2. **Medium term:** Monitor pnpm2nix-nzbr for PR #40 merge, then use **Option 1** with the stable fork

3. **Long term:** Consider contributing pnpm support to dream2nix for ecosystem consistency

## Updates to ADR-017

The original ADR-017 (if it exists) proposed using dream2nix with pnpm. This needs to be corrected:

- **dream2nix does NOT support pnpm lockfiles**
- The example code showing `translator = "pnpm-lock"` is incorrect
- Alternative approaches documented above should be used instead

## References

- [dream2nix modules](https://github.com/nix-community/dream2nix/tree/main/modules/dream2nix)
- [pnpm2nix (unmaintained)](https://github.com/nix-community/pnpm2nix)
- [pnpm2nix-nzbr fork](https://github.com/nzbr/pnpm2nix-nzbr)
- [PR #40: pnpm lockfile v9 support](https://github.com/nzbr/pnpm2nix-nzbr/pull/40)
