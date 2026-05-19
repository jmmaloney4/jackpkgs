# Plan: converge Node workspace sandboxing across checks, pre-commit, and just

## Goal

Replace the current patch-prone Node/TypeScript hook architecture with one shared workspace-runtime abstraction that all jackpkgs Node quality gates use consistently.

## Executive summary

The root problem is not "pre-commit is buggy" or "pnpm in Nix is weird".

The root problem is that jackpkgs currently has three partially-overlapping execution models for Node tooling:

1. `checks.nix` builds a writable sandbox copy of the repo and reconstructs a synthetic `node_modules` layout from a Nix store export.
2. `pre-commit.nix` generates separate inline bash wrappers that are trying to reconstruct the same layout again.
3. `just.nix` generates a local-dev recipe that assumes a normal devshell/runtime layout and does not share the sandbox logic.

Those three paths are supposed to express one conceptual contract:

- discover workspace packages
- make workspace-local imports resolvable
- make root and package-local dependencies resolvable
- resolve tool binaries from trusted locations
- run a tool over the requested package set

But the contract is not modeled explicitly. Instead it is reimplemented as ad hoc shell text in multiple modules.

That is why recent fixes have looked like rake-stepping:

- heredoc quoting broke generated bash
- relative `vitest` path broke after `cd`
- pre-commit used a read-only `node_modules` symlink while checks used a writable symlink forest
- pre-commit omitted per-package `node_modules` links that checks already knew about
- `just`, `checks`, and `pre-commit` still do not execute TypeScript in the same way

The correct direction is not "keep patching forever". The correct direction is a bounded refactor that makes the runtime contract explicit and shared.

## Root problem

### 1. Contract drift between modules

`modules/flake-parts/checks.nix`, `modules/flake-parts/pre-commit.nix`, and `modules/flake-parts/just.nix` each encode part of the Node tooling contract.

Symptoms:

- package discovery logic is repeated
- `node_modules` linking logic is repeated
- workspace symlink behavior is shared only partially
- binary lookup behavior differs by tool and module
- TypeScript execution semantics differ between `just`, `checks`, and `pre-commit`

Result: a fix in one path does not automatically fix the others.

### 2. Shell is the implementation language for architecture-critical behavior

Today the important behavior lives mostly in generated shell snippets embedded in Nix strings.

That makes correctness depend on:

- quoting
- indentation/dedent behavior
- `cd` context
- variable expansion order
- path relativity

This is too fragile for core infra behavior.

### 3. The exported Node workspace shape is underspecified

`jackpkgs.outputs.nodeModules` exports a useful but non-trivial filesystem shape:

- root `node_modules`
- nested `<pkg>/node_modules`
- pnpm symlink topology

Consumers currently need to know too much about that shape and reconstruct it manually in each runner.

### 4. We are testing string fragments more than behavior

There are useful unit tests, but many assertions are of the form:

- does generated script contain `ln -sfn`?
- does generated script contain `node_modules/.bin/vitest`?

Those tests catch regressions in emitted text, but they do not prove the filesystem/runtime contract actually works for:

- scoped packages
- workspace symlinks
- nested package-local deps
- tool execution from subdirectories

## Non-goals

- Do not redesign pnpm itself.
- Do not require every consumer repo to adopt TypeScript project references.
- Do not eliminate the `nodeModules` export.
- Do not add a giant generalized build system.

## Target architecture

Introduce one shared abstraction:

`jackpkgsLib.nodejs.mkWorkspaceRuntime`

This should be a Nix helper that produces the shell text or script payload needed to materialize a safe, writable, package-aware Node workspace runtime inside a working directory.

### Responsibilities of the shared runtime helper

Given:

- `nodeModules` derivation
- `workspaceRoot`
- `packages`
- tool name / binary requirements

it should provide one canonical setup sequence:

1. locate exported root `node_modules`
2. materialize a writable root `node_modules` symlink forest
3. link package-local `node_modules` directories for workspace members
4. link workspace package names into root `node_modules`
5. expose trusted tool binaries on `PATH`
6. optionally resolve a specific tool binary path

This helper should be the only place that knows the exported filesystem contract of `jackpkgs.outputs.nodeModules`.

### Then build tool runners on top of that

Separate the problem into two layers:

1. workspace runtime setup
2. tool invocation policy

Examples:

- `mkTscRunner`
- `mkVitestRunner`
- `mkBiomeRunner`

These should consume the shared runtime helper rather than rebuilding layout logic themselves.

### Script generation style

Follow ADR-038:

- use `pkgs.writeShellApplication`
- stop embedding large `bash -c ${''...''}` wrappers directly in hook entries
- use `runtimeInputs` where practical

This does not solve all architectural issues by itself, but it removes a major class of quoting/path bugs and gives shellcheck coverage.

## Recommended design decisions

### Decision 1: make `checks.nix` the canonical semantic model

`checks.nix` already has the more complete understanding of the runtime shape:

- writable root symlink forest
- package-local `node_modules`
- source copied to writable sandbox

Use that as the behavioral source of truth.

`pre-commit.nix` and `just.nix` should converge toward it, not independently evolve.

### Decision 2: move shared node workspace logic into `lib/nodejs-helpers.nix`

Add helpers roughly along these lines:

- `discoverPnpmPackages` (already exists)
- `mkWorkspaceSymlinks` (already exists)
- `mkLinkedNodeModulesRuntime` or `mkWorkspaceRuntime`
- `mkToolResolutionSnippet` or equivalent

The important thing is not the exact name. The important thing is that the runtime contract lives in one place.

### Decision 3: keep policy differences explicit

The modules do have legitimate differences:

- `checks.nix` runs in a copied writable sandbox
- `pre-commit.nix` runs in the git checkout through pre-commit
- `just.nix` runs in the user devshell

Those differences are fine.

What should *not* differ is the definition of:

- how workspace packages are discovered
- how node_modules is reconstructed
- how package-local deps are linked
- how workspace import links are created
- how tool binaries are found safely

### Decision 4: fix TypeScript semantics deliberately instead of incidentally

Right now:

- `just.nix` can run `tsc --project <pkg>/tsconfig.json` per package
- `pre-commit.nix` runs `tsc --noEmit` inside each package directory
- `checks.nix` still runs root `tsc --noEmit`

This is an architecture bug, not just an implementation detail.

Pick one model and document it. My recommendation:

- when `typescript.tsc.packages` is explicitly set or auto-discovered for a pnpm workspace, all three surfaces should run per-project type checks using each package's own `tsconfig.json`
- root-only `tsc --noEmit` should remain only as a fallback for true single-project repos

That matches the direction already captured in ADR-034.

## Proposed refactor phases

### Phase 1: stabilize and deduplicate runtime setup

Files:

- `lib/nodejs-helpers.nix`
- `modules/flake-parts/checks.nix`
- `modules/flake-parts/pre-commit.nix`

Work:

1. Extract the root + package-local `node_modules` linking logic from `checks.nix` into a shared helper.
2. Update `pre-commit.nix` to call the shared helper instead of carrying its own copy.
3. Keep behavior unchanged except for bug fixes.
4. Add tests that assert the shared helper output contains both root-link and package-link steps.

Success criteria:

- no duplicated node_modules reconstruction logic remains in `checks.nix` and `pre-commit.nix`
- the recent permission-denied and TS2307 regressions are covered by tests

### Phase 2: switch pre-commit runners to `writeShellApplication`

Files:

- `modules/flake-parts/pre-commit.nix`
- `tests/pre-commit.nix`
- optionally README/design docs if user-facing behavior changes

Work:

1. Replace raw inline `bash -c` wrappers for biome, tsc, and vitest.
2. Build the scripts with `writeShellApplication`.
3. Use `runtimeInputs` for bash/tool dependencies where possible.
4. Keep the emitted pre-commit entry small and stable.

Success criteria:

- no large multi-line hook scripts embedded directly in `entry`
- shellcheck runs on generated scripts through `writeShellApplication`
- behavior matches current passing path

### Phase 3: unify tool invocation policy across checks, pre-commit, and just

Files:

- `modules/flake-parts/checks.nix`
- `modules/flake-parts/pre-commit.nix`
- `modules/flake-parts/just.nix`
- `docs/internal/designs/034-multi-project-typescript-lint.md`
- possibly a new ADR if the final behavior differs materially from ADR-034

Work:

1. Define canonical TypeScript execution policy.
2. Implement the same package-selection + invocation strategy in all three surfaces.
3. Do the same audit for vitest and biome.

Recommendation:

- `tsc`: per-project where packages are known; root fallback otherwise
- `vitest`: explicit package list with stable binary resolution
- `biome`: package iteration only if package-level linting is really needed; otherwise consider root invocation with file globs if that is more natural

Success criteria:

- a repo configured one way in jackpkgs sees the same project set checked in `just lint`, pre-commit, and `nix flake check`
- documentation states any intentional divergence explicitly

### Phase 4: behavior-first regression tests

Files:

- `tests/pre-commit.nix`
- `tests/checks.nix`
- new fixture(s) under `tests/fixtures/` if needed
- possibly a buildable integration check in `flake.nix`

Work:

Add a minimal pnpm workspace fixture containing:

- one scoped workspace package
- one consumer package using `workspace:*`
- one package with package-local-only dependency
- one package without tests

Test behaviors, not just emitted substrings:

- root `node_modules` is writable enough for workspace symlink creation
- package-local dependency resolution works from subpackage `cwd`
- tool binary resolution still comes from trusted store paths
- pre-commit / checks run succeeds on the fixture

Success criteria:

- future regressions fail because behavior broke, not because a string changed

## Why this is the right scope

This is a bounded refactor, not a rewrite.

Keep:

- pnpm + `fetchPnpmDeps`
- exported `nodeModules` derivation
- current module surfaces (`checks`, `pre-commit`, `just`)

Change:

- where the runtime contract is defined
- how scripts are generated
- how consistently tools are invoked

That gets us out of reactive patch mode without turning jackpkgs into a science project.

## My recommendation

Do not just keep buckling down on one-off fixes.

Also do not attempt a giant redesign.

Do this instead:

1. land the minimal bug fixes already identified
2. immediately start Phase 1 extraction into shared nodejs helpers
3. in the same cycle or next one, implement ADR-038 for pre-commit runners
4. then unify TypeScript execution policy across `checks`, `pre-commit`, and `just`

That is the cleanest path from "works today" to "won't keep breaking in surprising ways".

## Suggested next concrete tasks

1. Add a shared helper in `lib/nodejs-helpers.nix` for reconstructing root + package-local `node_modules`.
2. Refactor `checks.nix` to call it without behavior change.
3. Refactor `pre-commit.nix` to call the same helper and delete duplicated runtime setup.
4. Update stale tests in `tests/pre-commit.nix` that still expect `ln -sfn "$nm_root" node_modules`.
5. Draft the `writeShellApplication` conversion for one runner first (`vitest` is a good pilot), then apply the pattern to biome and tsc.
6. Decide and document canonical TypeScript invocation semantics.

## Open questions

These are real but should not block Phase 1:

- Should biome remain per-package or run once at root?
- Should `just lint` use package auto-discovery by default or only explicit packages?
- Do we want one helper that returns shell text, or one helper that returns structured pieces (setup text, runtimeInputs, resolved binary path)?

My recommendation:

- Phase 1: shell-text helper is acceptable if it removes duplication immediately.
- Phase 2: move to `writeShellApplication` and structured composition.

## Acceptance criteria

- Shared node workspace runtime logic lives in one place.
- `checks.nix` and `pre-commit.nix` no longer drift on root/package `node_modules` reconstruction.
- Pre-commit Node runners are built with `writeShellApplication`.
- TypeScript invocation semantics are documented and consistent across `checks`, `pre-commit`, and `just`, or any intentional divergence is explicit.
- Tests cover behavior for workspace links, scoped packages, nested deps, and subdirectory execution.
