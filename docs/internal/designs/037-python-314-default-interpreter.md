# ADR-037: Bump the Default Python Interpreter to 3.14

## Status

Accepted

## Context

- `jackpkgs.python.pythonPackage` currently defaults to `pkgs.python312`.
- `pkgs/nautilus-trader/default.nix` also defaults to `python312` when callers do not provide an explicit interpreter.
- The repo already supports Python 3.14 in downstream consumers, and the 3.14 line is stable enough to be the default for new consumers.
- Keeping the default one minor behind creates avoidable churn for consumers that expect the flake to follow the supported baseline.
- Existing consumers can already override the interpreter explicitly when they need a different version.

## Decision

- `jackpkgs.python.pythonPackage` MUST default to `pkgs.python314`.
- Package definitions that follow the default interpreter, including `nautilus-trader`, SHOULD also default to Python 3.14 unless they have a stronger reason to pin something else.
- The override path remains unchanged: consumers MAY still set `jackpkgs.python.pythonPackage` or pass a different interpreter into package call sites.
- This change is limited to jackpkgs defaults and documentation. It does not force consumers to adopt Python 3.14.

## Consequences

### Benefits

- New consumers get the current supported baseline by default.
- The default matches the interpreter line already validated in downstream projects.
- Fewer projects need to override the interpreter just to avoid falling behind the supported baseline.

### Trade-offs

- Consumers that still need Python 3.12 or 3.13 must opt out explicitly.
- A default bump can surface compatibility gaps earlier in package builds and tests.

### Risks & Mitigations

- Risk: one or more packages may still assume 3.12-era behavior.
  - Mitigation: keep per-package overrides, and require the package to opt into a different interpreter only where needed.
- Risk: downstream consumers may rely on the old default implicitly.
  - Mitigation: the change is limited to defaults; explicit overrides continue to work and the README documents the new default.
- Risk: stale docs or tests could drift from the implementation.
  - Mitigation: update module docs, README, and the module tests in the same change.

## Alternatives Considered

### Alternative A — Keep the default on Python 3.12

- Pros: zero immediate behavior change for existing consumers.
- Cons: leaves the default one minor behind the validated baseline and keeps extra override burden on new consumers.
- Why not chosen: the repo has already validated 3.14 and should expose that as the default.

### Alternative B — Keep the default dynamic and inherit the consumer’s `pkgs.python3Packages.python`

- Pros: lets each consumer decide via its nixpkgs revision.
- Cons: makes the jackpkgs default less explicit and harder to reason about across repos.
- Why not chosen: jackpkgs is meant to provide opinionated defaults, not defer the decision entirely.

### Alternative C — Bump only package call sites, not the module default

- Pros: minimal surface area.
- Cons: consumers using the Python module would still land on the old default.
- Why not chosen: the module default is the primary user-facing behavior.

## Implementation Plan

- Update `modules/flake-parts/python.nix` to default `jackpkgs.python.pythonPackage` to `pkgs.python314`.
- Update package defaults that still hardcode `python312` to `python314`.
- Update the module README, design notes, and tests to match the new baseline.
- Validate with the standard jackpkgs checks before opening the PR.

## Related

- `docs/internal/designs/003-python-flake-parts-module.md`
- `README.md`
- `modules/flake-parts/python.nix`
- `pkgs/nautilus-trader/default.nix`
- `tests/pkgs.nix`

______________________________________________________________________

Author: Arthur
Date: 2026-05-17
PR: #<pending>
