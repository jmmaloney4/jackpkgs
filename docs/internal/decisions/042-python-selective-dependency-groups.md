# ADR-042: Selective Dependency Groups for Python Environments

## Status

Proposed

## Context

- `jackpkgs.python.environments.<name>` builds each uv2nix virtual env one of two
  ways: an explicit `spec` (a per-member `{ pkg = [groups]; }` map), or — when
  `spec` is null — `computeSpec { includeGroups }` where `includeGroups` is a
  **boolean** selecting between exactly two uv2nix presets: `workspace.deps.groups`
  (every member, **all** PEP 735 groups) or `workspace.deps.default` (production
  only). There is no middle ground.
- Consequences of the all-or-nothing lever:
  - **No lean check env.** Zeus's CI/dev-tools env (`python-nautilus-dev`) uses
    `includeGroups = true`, so it pulls *every* group. When Zeus added a `research`
    dependency group for its MyST-NB docs site (Sphinx/myst-nb/matplotlib), those
    deps landed in the check env even though pytest/mypy/ruff never need them. The
    only alternative today is to hand-write a full `spec` enumerating every member —
    duplicating what uv2nix already derives and re-maintaining it on every workspace
    change.
  - **No group on an explicit-spec env.** The editable devshell env
    (`python-nautilus-editable`) must keep its hand-built all-members `spec`, so it
    can *never* take on a single group without rewriting that spec. This is why the
    Zeus research site is served from the uv-managed `.venv` rather than the devshell
    (see zeus PR #1339).
- Prior art: ADR-034 (devshell composition contract), ADR-041 (workspace path
  derivation). Both push toward *deriving* env configuration from the uv workspace
  rather than hand-maintaining parallel lists; this ADR continues that direction for
  group selection.
- A second-order constraint: `lib/python-env-selection.nix` auto-discovers *which*
  non-editable env provides the quality-gate tools (pytest/mypy/ruff) for the
  `checks`, `just`, and `pre-commit` modules using the predicate
  `includeGroups == true`. Any change that lets an env carry a *subset* of groups
  must not silently break this discovery.

## Decision

Add three backward-compatible options to `jackpkgs.python.environments.<name>`,
plus one eval-time assertion. All existing configs behave identically.

- **`includeGroups` accepts `bool | [string]`** (MUST remain `nullOr` with the same
  null-defaulting: `true` for editable, `false` otherwise). List form selects named
  groups for the **computed** spec only:
  - For each member, the effective groups are that member's `default-groups`
    UNIONED with the requested names the member actually defines (mirroring
    `uv sync --group X`). Members that do not define a requested group skip it.
  - `[]` is therefore equivalent to `false`.
  - An explicit `spec` still overrides `includeGroups` **entirely** — unchanged
    contract. When both are set, `includeGroups` is ignored (as the boolean always
    was).
- **New `groups` option** (`attrsOf (listOf string)`, per member) composes ONTO the
  final spec — computed *or* explicit — via union. This is the escape hatch for an
  explicit-spec env (e.g. the editable devshell) to gain a group without rewriting
  its spec. `includeGroups` shapes the computed spec; `groups` always adds.
- **New `provideDevTools` option** (`nullOr bool`). Devtools discovery becomes:
  `provideDevTools == true`, OR (`provideDevTools` unset AND `includeGroups == true`).
  This decouples "runs the checks" from "how groups are computed" and is the opt-in
  for a lean list-form env to still back the quality gates. Backward-compatible:
  existing all-groups envs (flag unset) are still auto-discovered.
- **Assertion (MUST):** every group name referenced by a list-form `includeGroups`
  must be defined by at least one workspace member; every `groups` key must be a
  workspace member and each of its values a group *that member* defines. Otherwise
  evaluation fails with a message naming the unknown token and listing the available
  groups/members. This closes the silent-empty-intersection failure mode a typo would
  otherwise cause.

Scope: the pure combinators live in `lib/python-group-spec.nix`
(`resolveSpec`, `composeGroups`, `validateGroupSelection`) so they are unit-tested
against synthetic `deps` attrsets independent of any uv2nix workspace. `computeSpec`
keeps its signature (delegates to `resolveSpec`) so existing callers are unaffected.

Out of scope: PEP 621 optional-dependencies (uv2nix does not support them here);
per-group *package* overrides; changing the editable-env-count or unique-name
invariants.

## Consequences

### Benefits

- A check/CI env can carry exactly `[ "dev" "test" ]` instead of every group,
  keeping unrelated doc/research/notebook deps out of the quality-gate closure.
- An explicit-spec env (editable devshell) can opt into a single group via `groups`
  without abandoning its derived spec.
- Typos fail fast at eval with an actionable message, rather than silently yielding
  an env missing the intended deps.
- No behavior change for any existing consumer; the new surface is purely additive.

### Trade-offs

- Three group-related knobs (`includeGroups`, `groups`, `provideDevTools`) is more
  surface than one boolean. Mitigated by clear docstrings stating the one-line rule
  for each and by keeping `provideDevTools` unset-by-default (heuristic preserved).
- `includeGroups` is silently ignored when an explicit `spec` is present. This
  matches the prior boolean contract, but a user setting both may be surprised; the
  option docs call it out and direct them to `groups` for additive behavior.

### Risks & Mitigations

- *Risk:* list-form `includeGroups` breaks devtools discovery, making the gates
  build a redundant all-groups env. *Mitigation:* the `provideDevTools` flag (this
  ADR) is the explicit opt-in; discovery keeps the `== true` fallback so nothing
  regresses when the flag is unset.
- *Risk:* the pure combinators drift from the real uv2nix `deps` shape.
  *Mitigation:* `resolveSpec` consumes `workspace.deps.default`/`.groups` verbatim;
  the module wires them with no reshaping, and the downstream Zeus consumer PR
  (which instantiates the module against a real workspace and builds
  `python-nautilus-dev`) is the end-to-end proof.

## Alternatives Considered

### Alternative A — Merge everything into one `groups` knob

- Make `groups` the single option accepting `true` | `[names]` | `{member=[names]}`,
  always composing onto the spec; drop the bool/list split on `includeGroups`.
- Pros: one concept; smallest option surface.
- Cons: changes `includeGroups` semantics — a boolean `includeGroups = true` on an
  explicit-spec env would begin *adding* groups where today it is ignored. That is a
  silent backward-compat break for existing consumers.
- Why not chosen: preserving the exact current contract of `includeGroups` (and
  `spec`-overrides-`includeGroups`) is worth one extra option.

### Alternative B — Broaden devtools discovery to "any non-empty groups"

- Discovery = `includeGroups == true` OR non-empty list; no `provideDevTools`.
- Pros: zero new options for the discovery problem.
- Cons: an env with `includeGroups = [ "research" ]` (no test tools) could be picked
  as the check-tools env → `mypy: command not found`. Trades a redundant-build
  failure for a wrong-env failure that is harder to diagnose.
- Why not chosen: explicit intent (`provideDevTools`) is more robust than a heuristic
  guessing whether a group set contains the tools.

### Alternative C — Leave the module as-is; document the limitation

- Pros: no change.
- Cons: the motivating use cases (lean check env; group on the editable env) stay
  unserved; downstream repos keep hand-writing full specs.
- Why not chosen: the derive-don't-duplicate direction of ADR-034/041 argues for
  fixing it in the module.

## Implementation Plan

- `lib/python-group-spec.nix`: pure `resolveSpec` / `composeGroups` /
  `validateGroupSelection`.
- `modules/flake-parts/python.nix`: new options (`includeGroups` type widened,
  `groups`, `provideDevTools`); `computeSpec` delegates to `resolveSpec`; `pythonEnvs`
  validates then composes `groups` onto the base spec.
- `lib/python-env-selection.nix`: `isDevToolsEnvCandidate` honors `provideDevTools`
  with the `includeGroups == true` fallback.
- `tests/python-group-spec.nix`: nix-unit coverage of all three combinators
  (including the three throw paths) and the discovery predicate.
- Rollout: additive; no migration. Downstream consumers adopt at will. First
  consumer: Zeus flips `python-nautilus-dev` to `includeGroups = [ "dev" "test" ]`
  - `provideDevTools = true` after bumping its jackpkgs input.
- Rollback: revert; no persisted state.

## Related

- Zeus PR #1339 (MyST-NB research site; motivating case for a lean check env and a
  group on the editable env).
- ADR-034 (devshell composition contract), ADR-041 (workspace path derivation).

______________________________________________________________________

Author: Jack Maloney
Date: 2026-07-07
