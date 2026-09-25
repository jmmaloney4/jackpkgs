# ADR-050: Shared NixOS / nix-darwin / Home Manager Module Conventions

## Status

Accepted (operator decisions final 2026-09-21; decision 5/darwin-scope amended 2026-09-25 — see below; OD-B and OD-C remain open and recorded, unresolved, under "Open decisions"; OD-A closed as moot by the 2026-09-25 amendment)

> **Amendment, 2026-09-25 (operator):** Darwin scope (garden#2074 decision 1; ADR-050 Decision 5 below) changes from "whole `modules/darwin` tree promotes in PR 4" to **strict**: garden's `nixfiles/modules/darwin/**` tree stays in garden in its entirety and is not promoted to jackpkgs. "PR 4 (darwin services)" is dropped from the implementation plan; garden#2074 Part B now completes after PR 3. Rationale: no seven host is darwin, and with decision 4's no-hardcoded-identity parameterization requirement, promoting garden-only darwin modules would cost real parameterization work for tidiness alone — there is no second consumer to justify it. All other ADR-050 decisions (plumbing = hybrid, decision 3; personal-ness = middle ground, decision 4; dormant frameworks stay in garden and old PR 0 stays dropped, decision 6) stand unchanged. See the amended Decision 5, the updated Darwin-scope alternative, the closed OD-A, and the renumbered Implementation Plan below.

## Terms

This ADR spans two repos, so both vocabularies are defined here.

Garden side (the source tree being promoted):

- **garden `nixfiles/`** — the Nix configuration tree in `jmmaloney4/garden` whose shared modules (`nixfiles/modules/{common,network,nixos,darwin}`, `nixfiles/profiles/`, `nixfiles/home/`) are the promotion source, inventoried in the garden#2074 comment of 2026-09-17.
- **seven** — `room-of-requirement/seven`, the repo receiving the four rke2 cluster hosts (`bellatrix`, `gilderoy`, `itachi`, `voldemort`) per garden ADR 173. Currently a README-only stub; #2075 creates its machines.
- **fleet glue** — modules that configure the machine fleet itself rather than one upstream thing: user accounts, nix daemon settings, ssh, tailscale domain, base packages. In garden these live under the `jmmaloney4.*` option namespace.
- **service/program module** — a module that wraps exactly one upstream service or program (`services.imessage-bridge`, `programs.tod`, garden's future `services.tailscale` additions).

jackpkgs side (the destination):

- **cheap input** — a public, small-lock-closure flake input whose pin jackpkgs may declare: `agenix`, `determinate-nix`.
- **heavy/private input** — an input with a large lock closure or a private origin that jackpkgs MUST NOT declare: `nixvim`, `hermes`(-agent), and `deploy-rs` (declared but not held: see Decision 3).
- **package option** — a `types.package` option with a `pkgs.<name>` default and matching `defaultText` (mkPackageOption style), as in `modules/nix-darwin/imessage-bridge.nix`.
- **required option** — an option with no default. Evaluating a config that reads an undefined required option fails at eval time ("option … used but not defined"). This is the loud-failure mechanism.
- **identity / topology value** — a value that differs per operator or per deployment site: SSH keys, git identity, accounts, hostnames/IPs, tailnet domain, cache endpoints, substituter keys.
- **follows** — the flake-input override (`inputs.jackpkgs.inputs.<name>.follows = "<local input>";`) letting a consumer replace one of jackpkgs' pins with its own.
- **NUR-quirk path** — `pkgs.homeManagerModules`, the Home Manager module set `overlay.nix` leaks into the package overlay for legacy NUR consumers. Not a flake output; unchanged by this ADR.

## Context

### Problem

- garden#2074 Part B (per the #1883 Phase F operator decision and garden ADR 173 §2/Appendix C) promotes garden's shared Nix modules into jackpkgs so that both garden's hosts (`cedric`, `hermione`, `vernon`) and seven's four cluster hosts can import one module set, each repo keeping only its own hosts.
- Nothing consumes these modules today beyond garden itself: zeus/yard/sector7 use only jackpkgs' flake-parts surface; seven does not exist yet. The thing this unblocks is seven's machine bootstrap (#2075) — whose Pulumi stacks in turn depend on sector7's `deploy-lib` dual-mode resolver (sector7 ADR 035, garden#2074 Part A).
- Every convention decision below was made by the operator on 2026-09-21 against the full module-by-module inventory in the garden#2074 comment of 2026-09-17 (authoritative on scope) and its 2026-09-21 re-ground (authoritative on current state). This ADR records those decisions; it does not re-derive them.

### Ground truth about jackpkgs at `origin/main` `c618178`

- `modules/nixos/default.nix` is literally `{ }` — zero NixOS modules exist.
- The flake exposes exactly one darwin module by path (`darwinModules.imessage-bridge`) and has **no `nixosModules` or `homeModules` outputs at all**. The Home Manager module (`modules/home-manager/programs/tod.nix`) is reachable only through the NUR-quirk `pkgs.homeManagerModules` path in `overlay.nix`.
- Existing module conventions: upstream-style option namespaces (`services.imessage-bridge`, `programs.tod`), plain `{config, lib, pkgs, ...}` modules, packages resolved via package options defaulting into `pkgs` (`pkgs.imessage-bridge`), `mkEnableOption` gating.
- `AGENTS.md` declares README scope "flake-only … No legacy/Home Manager/NixOS module examples", and ADR-008's documentation scope excludes the `modules/nixos/` and `modules/home-manager/` trees. Both are amended by this PR.
- Consumers that follow jackpkgs' pins: garden's `flake.nix` sets `nixpkgs.follows = "jackpkgs/nixpkgs"` (and likewise for `home-manager`, `flake-parts`, etc.). Every input jackpkgs declares is therefore lock-weight for every follower, used or not.

### Constraint that shaped the plumbing decision

jackpkgs is a public, NUR-style repository. Identity values hardcoded in garden (Jack's literal RSA key in `nixfiles/modules/common/ssh.nix`, git identity in `nixfiles/home/programs/git.nix`, the `charles` account's ed25519 key) live in a private repo today. Promotion without a rule would move them into a public one.

## Decision

### Decision 1 — Flake output shape

- jackpkgs exposes the three module families as flake outputs:
  - `nixosModules.<name>` — new family, un-stubbed from `modules/nixos/default.nix` (the aggregator). PR 1 ships `nixosModules.default` only; PR 2 adds the named modules.
  - `darwinModules.<name>` — existing family, extended with `darwinModules.default` (the `modules/nix-darwin/default.nix` aggregator). The existing `darwinModules.imessage-bridge` entry is unchanged.
  - `homeModules.<name>` — new family under the modern Home Manager output name. `homeModules.default` imports `modules/home-manager/default.nix`; `homeModules.tod` imports `modules/home-manager/programs/tod.nix` directly. jackpkgs does **not** mint a legacy `homeManagerModules` flake output; the NUR-quirk `pkgs.homeManagerModules` path in `overlay.nix` is unchanged for existing overlay consumers.
- Each tree has a `default.nix` aggregator importing the whole tree; named per-module outputs import single files so consumers can take a narrow slice.
- A cheap-input-backed output MAY be a list composing an upstream module with jackpkgs glue at the flake boundary, e.g. `nixosModules.agenix = [ inputs.agenix.nixosModules.default ./modules/nixos/agenix.nix ]` (final shape lands with PR 2, gated by open decision 5a). Consumers import the output and get both; no `specialArgs`, no per-consumer input wiring.

### Decision 2 — Option namespace

- Service/program-shaped modules MUST use the upstream option namespace (`services.<name>`, `programs.<name>`). Precedent: `services.imessage-bridge`, `programs.tod`.
- Fleet glue with no upstream namespace MUST live under a `jackpkgs.*` root. This **renames garden's `jmmaloney4.*` root during promotion**; the rename is absorbed by garden's per-PR adoption changes, which already rewrite every import and set every parameterized value.
- `jackpkgs.*` is chosen over keeping `jmmaloney4.*` because it matches the option namespace jackpkgs' own flake-parts modules already use (`jackpkgs.fmt`, `jackpkgs.just`, …), and because decision 6 makes the module set hypothetically usable by someone who is not `jmmaloney4`.
- Every promoted module MUST have an `enable` flag (`mkEnableOption`). This also fixes the garden modules the inventory flagged as unconditional: `gnupg-agent.nix`, `security-wrappers.nix`, darwin `defaults.nix`/`keyboard.nix`/`zenith.nix`.

### Decision 3 — Package and input plumbing: hybrid, done idiomatically (operator decision, final)

- **Cheap/public inputs are jackpkgs':** jackpkgs declares `agenix` and `determinate-nix` as flake inputs, landed with the first PR that consumes them (PR 2), not before.
- Their consumption is idiomatic and boilerplate-free:
  - upstream *modules* are composed at the flake boundary (Decision 1's list form), so a consumer never wires the input itself;
  - *packages* are consumed via mkPackageOption-style package options **with defaults** (`default = pkgs.<name>; defaultText = literalExpression "pkgs.<name>";`) — zero consumer boilerplate, fully overridable.
- **Heavy/private deps are consumer-side:** `nixvim`, `hermes`, and `deploy-rs` are never jackpkgs inputs. Modules needing them declare consumer-side options **with no default**. An option whose absence makes an *enabled feature* impossible MUST have no default, so the unwired state fails loudly at eval time ("option … used but not defined") — by construction, not by assertion. An optional capability a consumer may legitimately not want (e.g. deploy-rs on a non-deploy host) uses `types.nullOr types.package` with `default = null` plus `mkIf`, so "not wanted" is a spellable, intended state rather than a silent failure. Option descriptions for no-default options MUST document the required wiring.
- **`follows` is the sanctioned pin-override escape hatch.** A consumer that wants its own pin for a cheap input writes `inputs.jackpkgs.inputs.agenix.follows = "agenix";` in its own flake. This is supported; it is an escape hatch, not the default posture, and it can desync cheap-input versions between consumers that use it and those that do not (see Risks).
- Rationale: garden follows jackpkgs' pins for every input it shares, so declaring heavy inputs here would push nixvim's lock closure onto zeus/yard/sector7, which consume only the flake-parts surface and would feel the weight without ever using it.

### Decision 4 — Personal-ness: middle ground (operator decision, final)

- **No hardcoded identity.** SSH keys, git identity, accounts, and topology values are required options the consumer supplies — no defaults. This keeps the class of value that lives in private garden out of public jackpkgs, and gives seven its own values where the split differs.
- **Everything that never varies stays opinionated and baked.** The fonts set, gnupg-agent-on, docker autoPrune policy, zsh as the shell, the base package list — taste and stable policy, not options.
- **Explicitly NOT maximally configurable:** no option for anything nobody varies. The test for adding an option: a concrete second consumer value must exist or be imminent (garden vs seven differing values qualify; a hypothetical third party alone does not).
- Net position: hypothetically usable by someone else — they point the identity/topology options at their own values — but not adaptable in taste.
- Concrete instances at promotion (PR 2/3):
  - `nixfiles/modules/common/ssh.nix`: the literal RSA key becomes a required option (`jackpkgs.ssh.authorizedKeys`, no default), and the authorizedKeys fan-out is gated behind the module's `enable` (the inventory's noted ungated-block bug);
  - `nixfiles/home/programs/git.nix`: identity becomes a required option;
  - `nixfiles/profiles/charles.nix`: the literal ed25519 key becomes an option with no default;
  - `nixfiles/modules/common/default.nix`: the malformed `jmmaloney4.tailscale-domain` option (bare attrset, no `mkOption`) is fixed at promotion as a proper required option — a tailnet domain is topology;
  - attic endpoint/cache names/pubkeys (garden defaults today: `attic.mellori-delta.ts.net`, `jmmaloney4`/`cavinsresearch`) become required options with no garden-side default; garden and seven each set their own.

### Decision 5 — Darwin scope (garden#2074 decision 1) — AMENDED 2026-09-25

**Current decision (strict, operator, 2026-09-25 — supersedes the 2026-09-21 answer below):**

- garden's `nixfiles/modules/darwin/**` tree stays in garden **in its entirety** and is **not** promoted to jackpkgs. jackpkgs' darwin module family remains exactly `darwinModules.imessage-bridge` (plus this PR's `darwinModules.default` aggregator, which was already home to `imessage-bridge.nix` before this ADR — see Consequences/Trade-offs) — no further darwin modules are promoted under this ADR.
- The planned "PR 4 (darwin services)" is dropped from the implementation plan below. garden#2074 Part B completes after (the renumbered) PR 4, garden final cleanup.
- Rationale: no seven host is darwin (seven's four cluster hosts are all NixOS per garden ADR 173), and decision 4's no-hardcoded-identity rule means every promoted darwin module needs its identity/topology values parameterized before it can leave garden. Doing that work for modules with no second consumer buys tidiness (one convention set) and nothing else — the cost is real, the benefit isn't.
- Consequence for OD-A: closed as moot — see "Open decisions" below.

**Original 2026-09-21 answer (superseded by the above):**

- The whole garden `modules/darwin/` tree promotes to jackpkgs in PR 4 — one module tree, matching jackpkgs' existing darwin surface — minus what other decisions exclude: `hermes-skills-sync.nix` and `homebrew.nix` stay garden-side (garden repo/PR semantics and personal taste); `hermes-agent.nix`/`hermes-webhook-filter.nix` ride open decision 2; `macos-vm.nix` stays in garden per decision 7.
- This PR records the decision only; nothing darwin promotes here.

### Decision 6 — Dormant frameworks stay in garden (operator decision, final)

- `nixfiles/modules/common/nix-remote-builders.nix`, `nixfiles/modules/nixos/gui.nix`, and `nixfiles/modules/darwin/macos-vm.nix` are **not promoted** — they stay in garden (enabled nowhere or one-host-only, per the inventory).
- The old **PR 0 (garden deadwood removal) is dropped** from the sequence. Consequences: the per-module prune-vs-promote calls PR 0 would have made are moot; the fixes PR 0 carried for files that still promote (the malformed `tailscale-domain` option, ssh's ungated authorizedKeys block) land with PR 2's parameterization of those same files; the deletions PR 0 carried for garden-only deadwood (`modules/common/emacs.nix`, `modules/darwin/ipfs.nix`, `profiles/code.nix`, unused `home/programs/{emacs,keychain,wezterm}.nix`) are simply not sequenced — anyone may prune them in garden later.
- PR 2's and PR 4's promotion lists in the 2026-09-17 plan are adjusted accordingly: `nix-remote-builders.nix` leaves PR 2's list, `macos-vm.nix` leaves PR 4's.

### Decision 7 — Documentation scope

- ADR-008 (module documentation generation) is amended in this PR: its in-scope set grows from `modules/flake-parts/**` to include `modules/nixos/`, `modules/nix-darwin/`, and `modules/home-manager/`. Option docs for the new trees ride ADR-008's existing plan once the trees carry options.
- `AGENTS.md` README-scope is amended to include the module outputs (`inputs.jackpkgs.nixosModules`, `darwinModules`, `homeModules`), and `README.md` gains a short module-outputs section in the same pass.

## Open decisions (recorded, not resolved)

These gate later PRs and return to the operator with this ADR.

### OD-A — Do the hermes modules move? (garden#2074 open decision 2; CLOSED as moot, 2026-09-25)

**Closed as moot, 2026-09-25:** the darwin-scope amendment to Decision 5 makes this question moot rather than answering it — no darwin promotion happens at all under this ADR, so `hermes-agent.nix` and `hermes-webhook-filter.nix` stay in garden along with the rest of `modules/darwin/`, by construction, not by a choice between (a) and (b) below. `hermes-skills-sync.nix` was already staying in garden outright regardless of this decision. The original framing is preserved below for context, in case a future ADR reopens darwin promotion with a real second consumer.

`nixfiles/modules/darwin/hermes-agent.nix` (472-line gateway launchd stack, well-formed options) and `hermes-webhook-filter.nix` (GitHub-webhook @-mention prefilter daemon) are generic in shape but consume garden's `hermes-agent` input/overlay and run on hermione only. `hermes-skills-sync.nix` is garden-specific outright (hardcodes `jmmaloney4/garden.git`, skills/memories layout, PR semantics) and stays in garden under every option.

- **Option (a) — stay in garden for now** (the 2026-09-17 inventory's proposal): revisit if a second gateway host appears. Pros: jackpkgs carries no module whose primary input is a private repo; zero work. Cons: hermione keeps a large module garden-side that a future second host would then duplicate.
- **Option (b) — promote under decision 3's heavy rule**: module moves with a `package` option that has no default and fails loudly when unwired. Pros: one tree; the heavy rule already covers the shape. Cons: a promoted module that is inert-by-default and only one host can wire; review and maintenance cost now for a consumer count of one.

### OD-B — `seventh-floor.nix` destination (garden#2074 open decision 4; gates the #2075 cutover; needs a garden ADR 173 erratum either way)

garden ADR 173 §2 lists `modules/network` in the jackpkgs set, but `nixfiles/modules/network/seventh-floor.nix` is the hardcoded cluster LAN — `10.77.7.0/28`, per-host MAC/IP table, NIC rename to `cluster0` — consumed only by the four seven hosts.

- **Option (a) — seven**, with a one-line garden ADR 173 erratum (the inventory's proposal; evidence over letter). Pros: topology hardcoded for exactly one consumer stays with that consumer; consistent with decision 4's "no options for things nobody varies" (exactly one varying party exists). Cons: ADR 173's letter changes.
- **Option (b) — jackpkgs per the ADR letter**, with the per-host table parameterized into required options per decision 4. Pros: one module tree; ADR text unchanged. Cons: an option surface with a consumer count of one, straining decision 4's own test.

### OD-C — agenix glue ownership and the cross-boundary token (garden#2074 open decision 5; gates PR 2's agenix shape and the #2075 secrets split)

Interacts with decision 3: the `agenix` *input* is already sanctioned as cheap; what stays open is who owns the *glue*, and where one specific secret lives.

- **(a) Glue ownership.** Garden's glue today is six lines per tree (`nixfiles/modules/nixos/agenix.nix`: import `inputs.agenix.nixosModules.default` + `age.identityPaths`; a darwin twin).
  - **Option (a1) — jackpkgs owns the glue** (`nixosModules.agenix = [ inputs.agenix.nixosModules.default ./modules/nixos/agenix.nix ]`): consumers import one output and set only `age.identityPaths`/secrets. Pros: zero per-repo boilerplate; decision 3's cheap-input story carried to its end. Cons: `identityPaths` default (`/etc/ssh/ssh_host_ed25519_key`) becomes a jackpkgs opinion every consumer inherits or overrides.
  - **Option (a2) — each repo keeps its own six-line `agenix.nix`** importing its own input: jackpkgs takes no agenix input after all. Pros: minimal shared surface; repos keep secret-bootstrap sovereignty. Cons: every repo re-declares the same six lines and re-pins agenix (or follows); decision 3's cheap-input list shrinks after it was decided.
- **(b) `hermes-op-token.age` cross-boundary secret.** The token is deployed to hermione and cedric (garden) *and* itachi and voldemort (→ seven), because `nixfiles/modules/common/zsh.nix` exported it fleet-wide (`HERMES_OP_SERVICE_ACCOUNT_TOKEN` from `age.secrets.hermes-op-token`). PR 2 generalizes that export into an "export env var from secret path" option with no built-in secret binding. Open: does the Hermes token belong on cluster nodes at all post-split, and if so, which repo's secrets tree carries it — and does seven wire the generalized option to it?

## Consequences

### Benefits

- seven bootstraps its four hosts from a public flake's module set (#2075's prerequisite) without forking garden's `nixfiles/`.
- garden's `nixfiles/` shrinks toward hosts + garden-only modules; both repos converge on one convention set instead of two drifting ones.
- Identity and topology values cannot silently move into a public repo — the option type makes the unwired state unevaluatable rather than merely discouraged.
- Heavy lock closures stay out of every jackpkgs follower's lock; cheap inputs arrive with zero consumer boilerplate.

### Trade-offs

- The `jmmaloney4.*` → `jackpkgs.*` rename is consumer churn, absorbed by garden's adoption PRs (which already rewrite those files).
- Two option-namespace styles coexist by rule (upstream-style for service/program modules, `jackpkgs.*` for fleet glue) — a convention to apply, not an accident to fix later.
- No-default options make enabled-but-unwired modules fail at eval — loud, correct, but the error surfaces at build time rather than review time; mitigated by requiring the wiring to be documented in the option description.
- `darwinModules.default` (this PR) keeps shipping even though garden's darwin tree will never promote into it (2026-09-25 amendment): unlike `nixosModules.default`, it is not an empty stub built to receive that promotion — `modules/nix-darwin/default.nix` already aggregated `imessage-bridge.nix` before this ADR, and Decision 1's "every family gets a `default` aggregator" convention applies independent of any garden promotion. `nix eval .#darwinModules --apply builtins.attrNames` is unaffected by the amendment: `["default","imessage-bridge"]` before and after.

### Risks & Mitigations

- **Risk**: `follows` overrides desync cheap-input versions between consumers (garden on jackpkgs' agenix pin, seven overriding to its own).
  **Mitigation**: documented as an escape hatch, not the default; consumers that use it own the divergence.
- **Risk**: the `default` aggregators grow into a wide interface consumers import wholesale.
  **Mitigation**: named per-module outputs exist from PR 1; the promotion lands in four independently reviewable PRs rather than one.
- **Risk**: decision 4's "no options for things nobody varies" is a judgment call applied per module during promotion.
  **Mitigation**: the test is written down (a concrete second consumer value must exist or be imminent), and each promotion PR's review applies it against the inventory's notes.

## Alternatives Considered

### Plumbing (decision 3)

- **All inputs in jackpkgs**: every dep (nixvim, hermes, deploy-rs) declared here. Pros: maximal zero-boilerplate; one pin owner. Cons: lock weight pushed onto every follower (garden follows jackpkgs for nixpkgs/home-manager/…; zeus/yard feel nixvim's closure without using it); private origins (hermes) in a public flake. Why not chosen: the follower graph makes input weight a shared cost, and the private-origin case is disqualifying outright.
- **Fully input-free modules** (mandatory package options everywhere): Pros: no lock weight, ever. Cons: boilerplate for the cheap/public deps nobody overrides; agenix/determinate-nix wiring re-declared per repo, which is exactly the duplication this promotion exists to remove. Why not chosen: it re-creates the drift the split is fixing, for the class of dep that never actually varies.
- **Hybrid (chosen)**: cheap inputs in, heavy out, `follows` as the sanctioned override.

### Personal-ness (decision 4)

- **Personal flake, identity baked in** (the inventory's original lean): Pros: cheapest; garden values copied verbatim. Cons: identity moves private → public; seven's differing topology forces parameterization anyway, so the hardcoded set would be inconsistent on arrival. Why not chosen: the split itself creates the second consumer that makes baked identity wrong.
- **Full parameterization**: Pros: generality for any third party. Cons: option surface becomes the complexity nobody asked for; taste becomes configuration. Why not chosen: no third party has asked; violates the no-options-for-unvaried-things test.
- **Middle ground (chosen)**: identity/topology required, taste baked.

### Option namespace (decision 2)

- **Keep `jmmaloney4.*`**: Pros: zero rename churn. Cons: a personal namespace on a public, hypothetically-shared module set; diverges from jackpkgs' own flake-parts namespace. Why not chosen: decision 6's "usable by someone else" makes the personal root incoherent.
- **All-upstream namespaces** (force everything under `services.*`/`programs.*`): Pros: one style. Cons: fleet glue has no upstream home; inventing fake upstream namespaces (e.g. `services.jackpkgs-user`) is worse than an honest `jackpkgs.*` root. Why not chosen: the two-style rule matches real module shapes.

### Darwin scope (decision 5) — updated 2026-09-25

- **Strict-shared reading (chosen, 2026-09-25)**: darwin stays in garden; PR 4 vanishes. Pros: no promotion work without a real second consumer — no seven host is darwin; avoids paying decision 4's no-hardcoded-identity parameterization cost for modules nobody but garden will ever wire. Cons: two darwin module trees (garden's full `modules/darwin/` and jackpkgs' single `imessage-bridge`) where one convention set was the original aspiration.
- **ADR-letter (original 2026-09-21 choice, superseded 2026-09-25)**: whole tree promotes in PR 4 minus the per-decision exclusions. Why superseded: the "one convention set" benefit doesn't materialize without a second consumer to actually use the promoted modules — it was uniformity for its own sake at real parameterization cost.

## Implementation Plan

The garden#2074 Part B PR sequence as it now stands (PR 0 dropped per decision 6; PR 4 "darwin services" dropped per the 2026-09-25 darwin-scope amendment to Decision 5 — Part B now completes after the renumbered PR 4 below; lists adjusted):

1. **PR 1 (this PR)** — conventions ADR + export scaffolding. `nixosModules.default`, `darwinModules.default`, `homeModules.{default,tod}` outputs; un-stub `modules/nixos/default.nix`; amend `AGENTS.md` and ADR-008; README module-outputs section. No consumer changes; no new inputs.
2. **PR 2** — seven-critical common/NixOS set + garden adoption PR (the #2075 unblock). Promotes `common/{user,nix,ssh,tailscale,attic,fonts,gnupg-agent,zsh,packages,nixbuild}.nix` and `nixos/{disks,docker,security-wrappers,tailscale}.nix` + aggregators (agenix shape gated by OD-C). `nix-remote-builders.nix` does **not** promote (decision 6). The `agenix` and `determinate-nix` inputs land here with their first consumer. Parameterizations in the same PR: attic endpoint/caches and the tailnet domain become required options; ssh authorizedKeys becomes a required option with the fan-out enable-gated; zsh's secret-env export generalizes to an "export env var from secret path" option with no built-in secret binding; `packages.nix` drops `inputs.deploy` — deploy-rs becomes a consumer-side `nullOr` package option per decision 3. Garden adoption: import `inputs.jackpkgs.nixosModules.*`, set the now-required values, delete the garden copies.
3. **PR 3** — profiles + home-manager tree + garden adoption. `profiles/{default,nixos,i18n,jack,plato,charles}.nix`, `home/{jack,plato}.nix`, `home/common/`, `home/programs/`. The `gardenSkillsHosts` assertion moves out of `profiles/jack.nix` to garden. **jackpkgs does not gain a `nixvim` input** — the 2026-09-17 plan's "jackpkgs gains nixvim" line is superseded by decision 3's heavy-input rule; the neovim HM module's nixvim wiring arrives consumer-side as no-default options. The `hostname`/`inputs` specialArgs the HM modules expect are documented at promotion.
4. ~~**PR 4** — darwin services (decision 5).~~ **Dropped, 2026-09-25** (darwin-scope amendment to Decision 5: no seven host is darwin, so nothing in `modules/darwin/` promotes). Original scope, preserved for context: clean set `keyboard`, `defaults`, `networking`, `tailscale-accept-routes`, `nix-gc-root-pruner`, `zenith`, `signal-cli`, `ollama`, `remote-builder`, darwin agenix (gated by OD-C); `dobby`/`voicememos-reader` moving only together with their packages; `macos-vm.nix` not promoting (decision 6); the hermes modules riding OD-A (now closed as moot).
5. **PR 4** (renumbered from PR 5; the original PR 4 above is dropped) — garden final cleanup, and the last PR in the Part B sequence. Delete all promoted files; `nixfiles/` reduces to `hosts/{cedric,hermione,vernon}`, the entire garden-only `modules/darwin/` tree (none of it promotes under this ADR — includes `hermes-skills-sync`, `homebrew`, the three dormant modules per decision 6, `hermes-agent`/`hermes-webhook-filter`, and everything that PR 4 above would have promoted), `secrets/`, garden-only overlays/inputs. `modules/rke2/**`, `seventh-floor.nix` (pending OD-B), and the four cluster hosts leave in the #2075 cutover, not here.

Local validation is the merge gate for all of these PRs while the self-hosted CI runners are down (garden#1636, hardware, no ETA — per the #2074 re-ground of 2026-09-21).

## Related

- garden#2074 (Part B scoping comment 2026-09-17 — authoritative inventory and original 5-PR plan; re-ground 2026-09-21 — operator decisions recorded in this ADR)
- garden#1883 (Phase F initiative), garden#2075 (seven's creation), garden#1636 (CI outage context)
- garden ADR 173 (`docs/internal/decisions/173-*.md` in jmmaloney4/garden) — the extraction this serves; OD-B is its pending erratum
- sector7 ADR 035 (`docs/internal/designs/035-deploy-lib-dual-mode-k8s-provider.md` in jmmaloney4/sector7) — the deploy-lib contract the seven hosts this module set will deploy
- ADR-008 — documentation scope, amended by this PR
- Precedent modules: `modules/nix-darwin/imessage-bridge.nix`, `modules/home-manager/programs/tod.nix`

______________________________________________________________________

Author: Claude, for Jack Maloney
Date: 2026-09-21
