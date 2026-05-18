# ADR-036: Unified `just cut` Release Recipe

## Status

Accepted

## Context

- jackpkgs provides `just bump` (patch) and `just release` (minor) recipes that create and push
  semver git tags. They do not modify version files, do not commit, and do not push the branch.
- Repos that publish versioned artifacts (sector7 release tarballs, future python packages) need
  the full flow: bump version files, commit, tag, push. sector7 carries a local `just cut` recipe
  in its justfile to do this.
- The local recipe is not reusable. Every repo that needs it would have to copy and adapt the same
  bash logic.
- The existing `bump` and `release` recipes are always enabled (hardcoded `enable = true` at
  `just.nix` line 352) and cannot be disabled or replaced by consumers.
- All current jackpkgs consumers use 0.x.y versioning. Under semver, 0.x has no stability
  contract. This is intentional: these are internal packages that move fast. Minor bumps may
  contain breaking changes. Patch bumps are fixes and additions. Major stays at 0 until a package
  earns a stability guarantee.

## Decision

### 1. Add `jackpkgs.just.cut` perSystem option

```nix
jackpkgs.just.cut = {
  enable = mkEnableOption "cut release recipe" // { default = false; };
  files = mkOption {
    type = types.listOf (types.submodule { ... });
    default = [ ];
  };
  commitMessage = mkOption {
    type = types.str;
    default = "release: {version}";
  };
  branch = mkOption {
    type = types.str;
    default = "main";
  };
};
```

Each file in `files` is a submodule:

```nix
{
  type = mkOption {
    type = types.enum [ "npm" ];  # future: "python", "cargo"
    default = "npm";
  };
  path = mkOption {
    type = types.str;
  };
}
```

When `enable = true`, the module generates a `cut` recipe in the `just-flake.features` justfile.

### 2. The `cut` recipe does the full release flow

```
cut level="patch":
    1. Pre-flight: verify on configured branch, clean working tree
    2. git pull --ff-only origin <branch>
    3. Source release-utils.sh → get_latest_tag
    4. Compute new version from latest semver tag + level
    5. Bump each configured file (type dispatch)
    6. git add <paths> && git commit -m "<message>"
    7. git tag -a "v$new_version" -m "Release v$new_version"
    8. git push origin <branch> "v$new_version"
```

With no files configured, steps 5-6 are skipped and the recipe goes straight to tag + push.

### 3. Absorb `bump` and `release` as aliases for `cut`

When `jackpkgs.just.cut.enable = true`, the existing `bump` and `release` recipes MUST be
replaced with one-line aliases:

```
bump:
    @just cut level="patch"

release:
    @just cut level="minor"
```

This replaces the current tag-only implementations. Consumers that already use `just bump` or
`just release` get the full flow automatically.

When `cut.enable = false`, `bump` and `release` retain their current tag-only behavior.

### 4. Versioning convention: 0.x "warp versioning"

All jackpkgs consumers SHOULD follow 0.x.y versioning:

- **0.MINOR.PATCH** where MINOR may contain breaking changes
- Patch bumps are fixes and backward-compatible additions
- Major version stays at 0 until the package earns a deliberate stability guarantee
- This is standard semver: "Major version zero (0.y.z) is for initial development. Anything MAY
  change at any time. The public API SHOULD NOT be considered stable." (semver.org spec item 4)

The module does not enforce this convention. It is a repo-level decision. But the default
`level="patch"` parameter encourages the smallest increment, and `release` aliasing to
`level="minor"` communicates that minor bumps are the "normal" release level for 0.x packages.

### 5. File type dispatch

The `type` field on each file determines the bump mechanism:

- `npm`: uses `node -e` to parse and rewrite `package.json` with the new version. Preserves
  existing indentation (tab-based for sector7, configurable by file).

Future types are additive changes to the enum and the dispatch table:

- `python`: sed on `version = "..."` in `pyproject.toml`
- `cargo`: sed on `version = "..."` in `Cargo.toml`

The dispatch happens at Nix eval time. The generated bash contains only the commands relevant to
the configured file types. No runtime type-string branching.

## Consequences

### Benefits

- Single recipe replaces three (local `cut`, `bump`, `release`) with one consistent flow.
- Version files are always bumped in sync with the tag. No drift between package.json version
  and git tag.
- Existing `just bump` / `just release` muscle memory works. They just do more now (version
  bump + commit + push, not just tag).
- Type enum makes unsupported package types a Nix eval error, not a runtime surprise.
- Reuses `release-utils.sh` and `justfile-helpers.nix` already in jackpkgs.

### Trade-offs

- When `cut` is enabled, `just bump` and `just release` now create commits on main and push.
  Previously they were tag-only. Consumers who relied on tag-only behavior must set
  `cut.enable = false`.
- The module only supports semver tags (`v0.0.0` format). Repos using a different tag scheme
  cannot use `cut`.
- `node` is required at runtime for `npm` file type bumps. This is already true in every
  pnpm-enabled devshell. For future `python`/`cargo` types, the same assumption applies to the
  relevant toolchain.

### Risks & Mitigations

- **Accidental release**: The recipe requires being on the configured branch with a clean tree.
  The pre-flight checks prevent accidental cuts from dirty states or wrong branches.
- **Push failure after commit**: If `git push` fails (network, auth), the commit and tag exist
  locally but not remotely. The user can retry `git push origin main "v$new_version"` manually.
  The recipe does not auto-rollback because a half-pushed state is worse than a locally-committed
  state the user can inspect.
- **Lockfile staleness**: For npm monorepos, workspace package versions do not appear in
  `pnpm-lock.yaml`. No lockfile or nix hash update is needed after a version bump. If this
  changes for future package types, the type-specific bump step can include a lockfile refresh.

## Alternatives Considered

### Alternative A — Keep `cut` local per repo

- Pros: full control per repo, no cross-cutting API to maintain.
- Cons: duplicated bash logic across repos. sector7 already has a copy. Next repo would copy it
  again. Bug fixes don't propagate.
- Why not chosen: the whole point of jackpkgs is shared infrastructure for repo-local
  operations. Release cutting qualifies.

### Alternative B — Use changesets or commitizen

- Pros: framework-grade versioning with changelog generation, per-package versioning in
  monorepos, team commit-message discipline.
- Cons: over-engineered for single-maintainer internal packages publishing tarballs, not npm
  registry. Adds framework dependency for a problem that a 40-line bash recipe solves.
- Why not chosen: the complexity budget doesn't justify it. A focused recipe is more honest.

### Alternative C — Keep `bump`/`release` tag-only, don't alias

- Pros: zero migration risk. Existing behavior preserved exactly.
- Cons: two disjoint workflows (tag-only vs full cut) that do overlapping things. Confusing
  for consumers. "Which one do I use?" becomes a question.
- Why not chosen: aliasing is cleaner. One mechanism, three names. The tag-only behavior was
  always a gap, not a feature.

## Implementation Plan

1. Add `jackpkgs.just.cut` options to `just.nix` (perSystem scope).
2. Generate the `cut` feature justfile using `mkRecipeWithParams` from `justfile-helpers.nix`.
3. When `cut.enable = true`, replace `bump` and `release` recipe generation with alias recipes.
4. Configure in sector7's `flake.nix`:
   ```nix
   jackpkgs.just.cut = {
     enable = true;
     files = [
       { path = "packages/sector7/package.json"; }
       { path = "package.json"; }
     ];
     commitMessage = "release: bump sector7 to {version}";
   };
   ```
5. Remove the local `justfile` `cut` recipe from sector7.
6. Add an `enable` option for the existing `release` feature (currently hardcoded `enable = true`)
   so consumers can fully replace tag-only recipes with `cut`. Separate PR.

______________________________________________________________________

Author: jmmaloney4
Date: 2026-05-11
