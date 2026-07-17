# ADR 044: Nixpkgs Package Override Pattern for Critical Tools

## Status

Accepted

## Context

- Jackpkgs consumers (zeus, garden, yard) depend on Nix for all tooling —
  formatters, linters, compilers, language servers. The canonical source for
  these packages is nixpkgs.

- nixpkgs package updates lag behind upstream releases. Typical delay ranges
  from days to weeks depending on the package's maintainer activity and PR
  review throughput in nixpkgs.

- When a pinned tool version in nixpkgs has a bug that blocks CI or corrupts
  output, consumers cannot wait for nixpkgs to catch up. They need an immediate
  fix.

- **Triggering case:** Biome `2.5.0` (the version in nixpkgs as of 2026-07-15)
  has a nondeterministic workspace-worker panic that corrupts JSON files during
  `biome check --write` in large monorepos under the Nix sandbox. The panic
  manifests as:

  ```
  could not downcast root node to language biome_js_syntax::syntax_node::JsLanguage
  ```

  After the panic, Biome rewrites some JSON files as if they were JavaScript,
  producing garbage like `("extends"); : "./tsconfig.base.json"`.

  Biome `2.5.4` (released 2026-07-15) is four patch releases ahead and may
  contain relevant fixes. nixpkgs-unstable is still on `2.5.0`.

- This is not a one-off. Similar version-lag scenarios will recur for any
  fast-moving tool that nixpkgs cannot update quickly enough. We need a
  repeatable pattern, not a one-time hack.

## Decision

- Jackpkgs MUST provide local package derivations for critical tools when the
  nixpkgs version is stale or buggy. These overrides live in `pkgs/<name>/`.
- The default implementation SHOULD use a standalone derivation that mirrors
  the nixpkgs package structure — calling `buildRustPackage` (or equivalent)
  directly with the updated `version`, `src`, and hash fields.
- The override package MUST be exposed through the jackpkgs overlay so all
  consumers see it as `pkgs.<name>`.
- Each override MUST include a comment documenting:
  - The nixpkgs version it overrides.
  - The target version.
  - The reason for the override (bug ID, upstream issue, etc.).
  - A removal condition: "Delete this override when nixpkgs ships >=
    `<target-version>`."
- Overrides SHOULD be deleted once nixpkgs catches up to the target version.

### Why `overrideAttrs` Does Not Work for Rust Packages

The initial plan was to use `overrideAttrs` on the nixpkgs `biome` derivation.
This would patch `version`, `src`, and `cargoHash` while inheriting all build
inputs and test configuration.

**This does not work.** `buildRustPackage` creates an internal fixed-output
derivation (FOD) for cargo vendoring (`*-vendor-staging.drv`). This FOD's
output hash is computed by nixpkgs' `fetch-cargo-vendor-util`, which produces a
different vendor layout than a manual `cargo vendor`. When you `overrideAttrs`
to change `cargoHash`, the old vendor-staging derivation is cached in the Nix
store with the original hash. The new `cargoHash` value never reaches the
cached FOD, producing an irreconcilable hash mismatch:

```
specified: sha256-z1KgScoH9retj0qNd6eOTjejjQypfVkha0ae71Z6TSg=
    got:    sha256-yV+lvPLPGtWCtbA39NVH1T1Sl1qn1MTsQIVRo3c9+Dg=
```

Even `lib.fakeSha256` cannot force a rebuild because the derivation path is
determined by its inputs, and the Nix daemon serves the cached `.drv` file.

**Conclusion:** For Rust packages using `buildRustPackage`, use a standalone
derivation (copy the nixpkgs `package.nix` and modify version/hash). For
non-Rust packages (e.g., npm-based tools), `overrideAttrs` may still work
because the hash mechanism differs.

### Scope

In scope:

- `pkgs/<name>/default.nix` files that build the tool from source using the
  same build framework as nixpkgs (`buildRustPackage`, `buildNpmPackage`,
  etc.).
- Wiring through `overlay.nix` and `flake.nix`.
- Documenting the override rationale and removal condition.

Out of scope:

- nvfetcher tracking for override packages (the source is fetched via
  `fetchFromGitHub` inside the derivation, and the hash changes per version).

## Consequences

### Benefits

- Immediate fix: consumers get the corrected version without waiting for
  nixpkgs.
- Centralized: all jackpkgs consumers benefit from the fix simultaneously
  through the overlay.
- Self-cleaning: each override documents its own removal condition, so
  routine nixpkgs bumps naturally surface candidates for deletion.

### Trade-offs

- Standalone derivations duplicate nixpkgs build logic (build inputs, cargo
  flags, test skips). When nixpkgs updates the upstream package, the local
  derivation may need manual sync. For patch-level bumps, this is rare.
- `cargoHash` must be computed via trial build (set placeholder → build → copy
  hash from the Nix error output). Note: `cargo vendor` locally produces a
  *different* hash than nixpkgs' `fetch-cargo-vendor-util`. Always use the
  hash Nix reports in its error message.
- Cold builds of large Rust workspaces take significant time (Biome 2.5.4
  took ~2 hours for checkPhase alone on aarch64-darwin). Subsequent builds
  are cached.

### Risks & Mitigations

- **Risk:** Override hashes break on nixpkgs bumps.
  - **Mitigation:** The derivation fails loudly at build time if hashes
    don't match. No silent corruption.
- **Risk:** Overrides accumulate and become permanent.
  - **Mitigation:** Each override documents the nixpkgs version it targets
    and the removal condition. Routine nixpkgs bumps should prompt cleanup.
- **Risk:** Override version has its own bugs.
  - **Mitigation:** Pin to a specific upstream release tag, not `main` or
    `latest`. Test the override via `nix build` before merging.

## Alternatives Considered

### Alternative A — `overrideAttrs` on nixpkgs derivation

- Pros: minimal code (15–25 lines); inherits all nixpkgs build improvements.
- Cons: **does not work for `buildRustPackage`** due to cargo vendor FOD hash
  caching (see "Why `overrideAttrs` Does Not Work" above).
- Why not chosen: confirmed non-functional for Rust packages during this ADR's
  implementation. May still be viable for non-Rust packages.

### Alternative B — Per-repo Nix override (consumer-side)

- Pros: no jackpkgs change needed; fastest single-repo fix.
- Cons: not shared — every consumer must independently discover the bug and
  implement the same override. Divergent versions across the ecosystem.
- Why not chosen: the problem is cross-repo and belongs in jackpkgs.

### Alternative C — Fetch pre-built binary from GitHub releases

- Pros: no compilation at all; fastest `nix build`.
- Cons: platform-specific tarball selection; less Nix-native; does not match
  jackpkgs conventions for from-source builds. Skips the nixpkgs test suite.
- Why not chosen: unnecessary overhead for maintaining platform matrix; from-
  source builds are more transparent and testable.

### Alternative D — Wait for nixpkgs to update

- Pros: zero work.
- Cons: indefinite delay; CI remains broken in the meantime. For corruption
  bugs, the cost of waiting is potentially destructive file writes.
- Why not chosen: not acceptable when the bug corrupts output.

## Implementation Plan

### Phase 1 — Biome override (this ADR)

- [x] Create `pkgs/biome/default.nix` as a standalone `buildRustPackage`
  mirroring the nixpkgs `pkgs/by-name/bi/biome/package.nix`.
- [x] Override `version` to `2.5.4`, `src` to the
  `@biomejs/biome@2.5.4` tag.
- [x] Compute `cargoHash` via trial build (use the hash Nix reports, not
  `cargo vendor` output).
- [x] Expose via `overlay.nix` and `flake.nix`.
- [x] Verify `nix build .#biome` produces a `2.5.4` binary.
- [ ] Bump zeus's jackpkgs input and validate `nix flake check`.

### Rollback

- Delete `pkgs/biome/default.nix`, remove the overlay entry. The treefmt
  stack falls back to `pkgs.biome` from nixpkgs.

## Related

- Biome downcast panic family: `biomejs/biome#5979`, `#7837`, `#9918`
- ADR 025: Overlay package patching pattern (proposed, unmerged)
- ADR 043: Standard lightweight LSP servers via jackpkgs.lsp (packaging
  pattern reference)

______________________________________________________________________

Author: Arthur
Date: 2026-07-15
PR: #<pending>
