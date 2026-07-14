# ADR-039: Shellcheck for Generated Pre-commit Hook Scripts

## Status

Accepted

## Context

- `modules/flake-parts/pre-commit.nix` generates bash entry points for biome lint, TypeScript `tsc`, and vitest pre-commit hooks.
- These scripts are assembled as Nix `''...''` multi-line strings with interpolated store paths, conditional sections, and eval-time loops (`lib.concatMapStringsSep` over package lists).
- Commit `9939358b` fixed a heredoc indentation bug: Nix auto-dedent left the `EOF` closing delimiter with leading whitespace, but bash `<<` (not `<<-`) requires it at column 0. The fix replaced heredocs with `echo` calls.
- That class of bug (bash syntax errors from Nix string quoting interactions) is hard to catch in review and only surfaces at hook runtime.
- These inline scripts are not shellchecked anywhere. There is no CI step for them and no build-time validation.
- The scripts mix Nix interpolation with bash logic in ways that make editing error-prone: indentation matters for both Nix dedent semantics and bash syntax, and the two conflict.

## Decision

- Pre-commit hook bash scripts MUST be assembled using `pkgs.writeShellApplication` instead of raw `bash -euo pipefail -c ${lib.escapeShellArg ''...''}`.
- `writeShellApplication` runs shellcheck on the final assembled text at Nix build time, catching syntax errors and common bash pitfalls before the hook ever executes.
- The scripts remain co-located in `pre-commit.nix` as Nix string expressions. We do NOT extract them to standalone `.sh` files at this time.
- The `runtimeInputs` parameter on `writeShellApplication` SHOULD be used to declare tool dependencies explicitly rather than relying on `$PATH` manipulation in bash.

## Consequences

### Benefits

- Shellcheck runs on every Nix evaluation that produces these hooks. Syntax errors like the heredoc bug from `9939358b` are caught at build time, not at `git push` time.
- `writeShellApplication` sets `set -euo pipefail` automatically, so the manual wrapper can be dropped.
- `runtimeInputs` makes tool dependencies declarative and inspectable.
- No new files, no new CI steps, no template substitution machinery.

### Trade-offs

- Shellcheck warnings that are false positives due to Nix interpolation (e.g., variables injected as literals that shellcheck sees as unset) will need `# shellcheck disable=` annotations or `runtimeInputs` placement.
- The scripts are still embedded in Nix strings. Indentation confusion between Nix dedent and bash readability is reduced but not eliminated.
- Shellcheck only runs when the Nix expression is evaluated (during `nix develop`, `nix build`, etc.), not as a standalone CI lint step on `.sh` files.

### Risks & Mitigations

- Risk: `writeShellApplication` may reject scripts that previously worked because shellcheck is stricter than bash.
  - Mitigation: add targeted `# shellcheck disable=` comments. These are explicit and auditable.
- Risk: Nix interpolation produces text that shellcheck misinterprets (e.g., `${tscExe}` looks like an unset variable).
  - Mitigation: shellcheck sees the final interpolated text, not the Nix expression, so store paths are visible as literal strings. This should not be a problem in practice.
- Risk: `writeShellApplication` wrapper behavior differs from raw `bash -c`.
  - Mitigation: `writeShellApplication` produces a wrapper script that sources the text in a bash session with `set -euo pipefail`. The runtime behavior is equivalent.

## Alternatives Considered

### Alternative A -- Extract to standalone `.sh` files with `replaceVars`

- Pros: `.sh` files can be shellchecked as a CI lint step. Clean separation of bash from Nix.
- Cons: requires converting Nix-eval-time conditionals and loops to runtime bash equivalents (arrays, env vars, arg parsing). Requires `@var@` placeholders and `replaceVars`/`substituteAll`. Significantly more code, more moving parts, and a new CI step to maintain.
- Why deferred: the ROI is lower than Option B below. The main value (catching syntax errors) is already delivered by `writeShellApplication`. Standalone shellcheck-in-CI is a refinement for when these scripts are edited frequently enough to justify the extraction cost.

### Alternative B -- `writeShellApplication` without file extraction (chosen)

- Pros: shellcheck on the assembled output with minimal refactoring. No new files or CI steps. Scripts stay co-located with their Nix config.
- Cons: no standalone shellcheck step. Scripts are still in Nix strings.
- Why chosen: addresses the root problem (uncaught bash syntax errors) with the smallest scope of change.

### Alternative C -- Status quo with manual review

- Pros: no work required.
- Cons: the bug class that produced `9939358b` will recur. Nix `''...''` quoting and bash syntax interact in ways that are hard to see in code review.
- Why rejected: the cost of the next runtime bug exceeds the cost of the `writeShellApplication` refactor.

## Implementation Plan

- Convert `biomeLintEntry`, `tscEntry`, and `vitestEntry` from raw `bash -euo pipefail -c ${lib.escapeShellArg ''...''}` to `writeShellApplication` derivations.
- Move tool binaries into `runtimeInputs` where practical.
- Add `# shellcheck disable=` annotations for any false positives.
- Validate by triggering each hook and confirming behavior is unchanged.
- Update this ADR with the PR number once opened.

## Related

- Commit `9939358b` -- the heredoc fix that motivated this decision
- `modules/flake-parts/pre-commit.nix` -- the affected file
- [nixpkgs `writeShellApplication`](https://nixos.org/manual/nixpkgs/stable/#trivial-builder-writeShellApplication)

______________________________________________________________________

Author: Arthur
Date: 2026-05-19
PR: #281
