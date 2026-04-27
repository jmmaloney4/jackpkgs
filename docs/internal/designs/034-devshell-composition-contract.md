---
id: ADR-034
title: Devshell Composition Contract
status: proposed
date: 2026-04-27
---

# ADR-034: Devshell Composition Contract

## Status

Proposed

## Context

`jackpkgs` exposes several reusable development-shell fragments through
flake-parts outputs, including:

- `config.jackpkgs.outputs.devShell`
- `config.jackpkgs.outputs.pulumiDevShell`
- `config.jackpkgs.outputs.pythonEditableHook`
- `config.jackpkgs.outputs.nodejsDevShell`

Consumers commonly compose these fragments into their final project shell with
`pkgs.mkShell { inputsFrom = [ ... ]; }`. This is convenient for packages and
setup hooks, but recent Pulumi environment fixes exposed a boundary problem:
variables declared as `env = { ...; }` on an upstream shell do not reliably appear
in the final consumer shell when that upstream shell is included via
`inputsFrom`.

The affected variables included the Pulumi non-interactive output defaults from
PR #205:

- `PULUMI_OPTION_NON_INTERACTIVE=true`
- `PULUMI_OPTION_COLOR=never`
- `PULUMI_OPTION_SUPPRESS_PROGRESS=true`

and the Node/Pulumi debugging flag from PR #242:

- `NODE_OPTIONS=--async-context-frame`

The same class of problem can affect any variable that is only represented as a
shell derivation attribute, rather than carried through the build-input/setup-hook
composition path.

Key constraints:

- Consumers should be able to compose jackpkgs-provided shell functionality
  without copying package lists or environment details into their own flakes.
- Environment behavior should be explicit and testable.
- Existing consumers already use `inputsFrom`; changing the public composition
  model should be avoided unless there is a clear correctness or ergonomics win.
- `jackpkgs` should not require every consumer to call a custom helper just to get
  the standard module-provided development environment.

## Decision

Continue using `mkShell` plus `inputsFrom` as the public composition mechanism
for development-shell fragments, but narrow its contract:

1. `inputsFrom` is appropriate for propagating packages, build inputs, and setup
   hooks.
2. `inputsFrom` MUST NOT be relied on to propagate `env` attributes or upstream
   `shellHook` behavior into a downstream shell.
3. Any environment variable that must be provided by a jackpkgs shell MUST be
   carried by a setup hook package included in that shell's inputs.
4. Modules SHOULD NOT duplicate durable environment exports through `env` attrs or
   `shellHook`. Those paths are easy to mistake for the composition contract and
   can drift from the setup hook.
5. `jackpkgs` SHOULD document reusable shell outputs as "shell fragments" whose
   stable interface is build inputs plus setup hooks, not the whole `mkShell`
   attribute set.

We will not introduce a public custom shell-composition function at this time.
Instead, each module that needs environment propagation should expose it through a
normal setup hook package, and include that package in the relevant dev shell.

## Consequences

**Benefits:**

- Keeps the consumer-facing API aligned with normal nixpkgs/flake practice:
  compose shell fragments via `inputsFrom`.
- Fixes the concrete Pulumi variables for consumers that wrap
  `config.jackpkgs.outputs.devShell` in their own project shell.
- Avoids a new jackpkgs-specific shell DSL that consumers would need to learn.
- Makes environment propagation testable by checking for setup-hook inputs and by
  entering a downstream shell with `nix develop`.
- Preserves direct-shell behavior for users who enter `pulumiDevShell` or
  `jackpkgs.outputs.devShell` directly.

**Trade-offs:**

- Setup hooks are less obvious than plain `env = { ...; }` attributes.
- The final shell does not expose these variables as evaluable derivation
  attributes even though they are present in the interactive environment;
  validation must include setup-hook presence checks and/or actual `nix develop`
  checks for important paths.
- Nix-level tests should avoid asserting `drv.VAR`; the source of truth is the
  setup hook included in the shell inputs.

**Risks and Mitigations:**

- *Risk:* Future modules add `env = { ...; }` to shell fragments and assume it
  propagates through `inputsFrom`.
  *Mitigation:* Document this ADR, keep tests for composed-shell propagation, and
  prefer helper patterns that derive setup hooks from an env attrset.

- *Risk:* Setup-hook ordering surprises if multiple fragments export the same
  variable.
  *Mitigation:* Treat duplicate environment ownership as a design smell. If a
  variable is intentionally overrideable, document the precedence and use normal
  shell semantics (`export VAR="${VAR:-default}"`) where appropriate.

- *Risk:* Setup hooks may run in contexts beyond interactive shell entry.
  *Mitigation:* Keep setup hooks limited to deterministic environment exports and
  avoid expensive side effects, prompts, filesystem writes, or network access.

## Alternatives Considered

### A: Use `env = { ...; }`

Pros: simple Nix syntax; easy to inspect with `nix eval`; works for direct
`mkShell` entry in many cases.

Cons: does not reliably propagate through downstream `inputsFrom` composition;
this is the root cause of the Pulumi and `NODE_OPTIONS` regressions.

Rejected because it does not satisfy the consumer composition requirement and
creates a misleading second path for environment propagation.

### B: Put all critical variables only in `shellHook`

Pros: visible in `nix eval ...shellHook`; familiar to shell users; works when
entering the shell directly.

Cons: upstream `shellHook` behavior is not a reliable contract for downstream
shells that compose with `inputsFrom`. It also mixes durable environment state
with human-facing shell-entry behavior.

Rejected because it is insufficient for wrapped consumer shells and creates a
misleading second path for environment propagation.

### C: Setup-hook packages carried through `inputsFrom`

Pros: uses the part of shell composition that is meant to cross derivation
boundaries: build inputs and setup hooks. It works for wrapped shells and can be
implemented without changing consumer flakes.

Cons: less obvious than `env`; requires tests that distinguish direct shell attrs
from final interactive environment.

Chosen because it preserves the existing public composition style while making
environment propagation reliable.

### D: Expose a custom `jackpkgs.lib.mkDevShell` composition function

Pros: could centralize package, env, and shellHook merging in one helper; could
provide a richer typed interface than raw `mkShell`.

Cons: every consumer would need to opt into a jackpkgs-specific wrapper. It would
still need to interoperate with third-party shell fragments that are already
`mkShell` derivations. It risks becoming a parallel shell framework rather than a
small reusable flake module library.

Not chosen now. A custom helper may be reconsidered if multiple modules need
structured merging that setup hooks cannot express, but the current problem is
solved by setup hooks with no consumer migration.

### E: Expose attrset fragments instead of shell derivations

Example shape:

```nix
jackpkgs.outputs.shellFragments.pulumi = {
  packages = [ ... ];
  env = { ...; };
  shellHook = ''...'';
};
```

Pros: explicit and mergeable; consumers or helper functions can combine fragments
without losing attr-level information.

Cons: changes the consumer contract, duplicates what `mkShell` already models for
packages, and requires migration or dual outputs. It also does not solve
composition with third-party `mkShell` fragments unless converted back into setup
hooks.

Not chosen for the current fix, but this is a plausible future direction if
jackpkgs needs a first-class shell-fragment API.

## Implementation Plan

1. Create a `pkgs.makeSetupHook` package (via `lib/shell-env-hook.nix`) that
   exports Pulumi environment variables and include it in
   `config.jackpkgs.outputs.pulumiDevShell` packages.
2. The pulumi module adds `pulumiDevShell` to `jackpkgs.shell.inputsFrom`, so
   the composed `jackpkgs.outputs.devShell` receives the setup hook through
   normal `inputsFrom` propagation — no duplicate env or hook in devshell.nix.
3. `shellHook` in `devshell.nix` is reserved for non-env side effects (welcome
   messages, gcloud profile setup). Durable env vars travel only through setup
   hooks.
4. Add tests that verify the setup hook package is present in both
   `pulumiDevShell` and the composed devShell, and that downstream composition
   via `nix develop --override-input` exposes the expected variables.
5. Validate with a real downstream composition using
   `nix develop --override-input jackpkgs <local-jackpkgs-checkout>` from a
   consumer repository.

## Appendix: Code Changes in PR #243

PR #243 implements this decision by updating:

- `modules/flake-parts/devshell.nix`

  - Removes the duplicate `pulumiEnv` attrset — environment is defined once in
    `modules/flake-parts/pulumi.nix` as `pulumiBaseEnv`.
  - Pulumi setup hook propagates through `inputsFrom` from `pulumiDevShell`;
    devshell.nix no longer builds its own hook.
  - `shellHook` reserved for non-env side effects only (welcome messages, gcloud
    profile setup).

- `tests/pulumi.nix`

  - Adds `NODE_OPTIONS` to expected Pulumi shell env.
  - Adds a composed-shell test that requires both shellHook exports and the setup
    hook package.

- `README.md`

  - Documents the shared Pulumi environment exported by the composed shell.

## Related

- PR #205: Pulumi non-interactive CLI defaults
- PR #242: `NODE_OPTIONS=--async-context-frame` for Pulumi/Node async stack traces
- PR #243: Propagate Pulumi env through composed shells
- `modules/flake-parts/devshell.nix`
- `modules/flake-parts/pulumi.nix`

______________________________________________________________________

*Author: Jack Maloney — 2026-04-27*
