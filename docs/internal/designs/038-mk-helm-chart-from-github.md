# ADR-038: `mkHelmChartFromGitHub` — Canonical Helm Chart Derivation Helper

## Status

Proposed

## Context

Helm charts that only ship inside upstream GitHub repos (no standalone OCI registry or chart tarball) need a `fetchFromGitHub` + `cp -r` derivation pattern. Across the `garden` repo there are four such derivations in `nix/helm-charts.nix`:

- `cert-manager-chart` — uses `rec { pname; version; }` with `hash`
- `gha-runner-scale-set-controller-chart` — uses `let version = ...; in` with `sha256`
- `rancher-chart` — uses `rec { pname; version; }` with `hash` and a complex buildPhase
- `envoy-gateway-crds-chart` — uses `let version = ...; in` with `hash`

The two styles (`rec` vs `let/in`) produce equivalent derivations but differ enough in attribute layout that Renovate's regex manager needs separate match patterns for each. The `sha256` vs `hash` attribute name split adds a third dimension.

This is a three-way style divergence with no functional justification, and it means the Renovate regex grows every time a new variant appears.

## Decision

Add `mkHelmChartFromGitHub` to the jackpkgs library. This function MUST:

1. Accept a strict, ordered attribute set: `pname`, `version`, `owner`, `repo`, `hash`, `chartSubdir`, plus optional `rev` (default `v${version}`) and `buildPhase` (default empty).
2. Produce a `stdenv.mkDerivation` that fetches from GitHub and copies `chartSubdir` to `$out`.
3. Use `hash` (SRI format) exclusively — `sha256` attribute name is not supported.

All current and future Helm chart derivations in garden (and any other repo using jackpkgs) MUST use this function instead of hand-writing `stdenv.mkDerivation`.

The Renovate regex manager in `sector7/renovate/nix.json` MUST be updated to match a single `mkHelmChartFromGitHub` call pattern, replacing the two existing `fetchFromGitHub` regexes.

## Consequences

### Benefits

- One canonical derivation style — no more `rec` vs `let/in` divergence
- Single Renovate regex target — the call-site attribute layout is fixed
- `hash` (SRI) is enforced by the function signature; `sha256` attr name is eliminated
- Adding a new chart is a single function call, not a copy-paste of a 20-line derivation
- The function is reusable across repos that import jackpkgs (garden, yard, etc.)

### Trade-offs

- Adds a domain-specific function to jackpkgs lib for a pattern that currently only appears in garden
- Callers lose the ability to customize `installPhase` (the function owns it)
- The `buildPhase` escape hatch preserves flexibility but callers still depend on the function's internal structure

### Risks & Mitigations

- **Risk**: If a chart needs more than `buildPhase` customization (e.g. `nativeBuildInputs`, `patches`), the function must be extended.
  - **Mitigation**: Add new optional attributes as needed. The function is small and easy to extend. The `buildPhase` string can already invoke any tool available in `stdenv`.
- **Risk**: Renovate regex false positives matching `mkHelmChartFromGitHub` calls that aren't Helm charts.
  - **Mitigation**: The function name is specific enough. `managerFilePatterns` already scopes to `/nix/.+\.nix$/`.

## Alternatives Considered

### Alternative A — Standardize on `rec {}` style, no function

Convert all derivations to `rec { pname = ...; version = ...; }` and keep the existing Renovate regex.

- Pros: Minimal change, no new function.
- Cons: Still copies a 20-line derivation boilerplate per chart. Still has `sha256` vs `hash` inconsistency. Still one regex per pattern class, not per function.
- Why not chosen: Doesn't prevent future drift. Every new chart is a copy-paste risk.

### Alternative B — Expand Renovate regex to match both `rec` and `let` patterns

Add a second `matchString` to the existing `fetchFromGitHub` regex manager.

- Pros: Quick fix, no code changes in garden.
- Cons: Regex grows. Each new Nix style needs another pattern. Already two patterns for what should be one thing.
- Why not chosen: This was implemented as sector7 PR #203 but closed in favor of this approach.

## Implementation Plan

1. Add `lib/helm-chart.nix` to jackpkgs with the `mkHelmChartFromGitHub` function.
2. Wire it through `lib/default.nix` as `helmChart.mkHelmChartFromGitHub`.
3. Write nix-unit tests validating the function produces derivations with correct attributes.
4. Update `garden/nix/helm-charts.nix` to use the function (separate PR).
5. Update `sector7/renovate/nix.json` to match `mkHelmChartFromGitHub` calls (separate PR, replacing #203).
6. Close sector7 PR #203.

## Related

- sector7 PR #203 (closed, superseded by this approach)
- garden `nix/helm-charts.nix`
- ADR-034 in garden (Nix-Managed Helm Charts for OCI-Only Registries)

______________________________________________________________________

Author: Jack Maloney
Date: 2026-05-18
PR: jackpkgs#274
