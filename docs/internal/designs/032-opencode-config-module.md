# ADR-032: opencode Configuration flake-parts Module

## Status

Proposed

## Context

### Problem

OpenCode MCP servers configured via `uvx`/`npx` at runtime suffer from
Python/Node environment contamination when run under Nix. Specifically,
`PYTHONPATH` set by Nix shell environments leaks Nix-store Python 3.13
packages into `uv`'s Python 3.12 venv, causing errors such as
`ModuleNotFoundError: No module named 'rpds.rpds'`. The same class of issue
affects Node-based servers that pick up the wrong `node_modules`.

Additionally, `opencode.json` (and companion config files like `dcp.jsonc`)
currently live only on disk as hand-edited files with no version-controlled,
reproducible source of truth.

### Requirements

- MCP server binaries MUST be isolated Nix derivations — no runtime `uvx`/`npx`
  invocations for servers that can be packaged.
- The opencode config MUST be expressible as Nix code and committed to version
  control.
- The same module MUST support two distinct use cases:
  1. **User-level** (`~/.config/opencode/opencode.json`) — managed via
     home-manager in `jmmaloney4/garden`.
  2. **Project-level** (`$PRJ_ROOT/opencode.json`) — managed via a flake-parts
     `perSystem` module in project repos such as `cavinsresearch/zeus`.
- The module SHOULD be a thin wrapper: first-class typed options for MCP
  servers (where packaging logic adds value); freeform `settings` passthrough
  for the rest of the opencode schema (providers, keybinds, LSP, agents,
  formatters, etc.).
- A home-manager module MAY be added in the future; it is out of scope for
  this ADR (see tracking issue).

### Constraints

- jackpkgs already has `modules/flake-parts/` with a canonical module pattern
  (see ADR-003). New modules MUST follow that pattern.
- `natsukium/mcp-servers-nix` already packages `serena`, `time`, `github`,
  `context7`, and others as `buildPythonApplication`/`buildGoModule`
  derivations with isolated dependency closures. We SHOULD reuse it rather
  than re-package.
- The official opencode JSON schema (`https://opencode.ai/config.json`) uses
  `plugin` (singular) for npm plugins. The user's existing `opencode.json`
  incorrectly uses `plugins` (plural), which the schema does not recognise;
  the generated config MUST use `plugin`.
- Secrets (API tokens) MUST NOT be written into the Nix store. OpenCode's
  own `{env:VAR_NAME}` runtime substitution syntax is used for remote server
  headers and is safe because it is never evaluated by Nix.
- `mcp-servers-nix` provides a standalone `lib.mkConfig pkgs config` function
  that returns a Nix store path to a generated config file. Its flake-parts
  module only officially supports `claude-code` and `vscode-workspace` flavors;
  for the `opencode` flavor `lib.mkConfig` MUST be called directly.

### Prior Art

- `natsukium/mcp-servers-nix` — upstream MCP packaging library; used as a
  dependency.
- `cameronfyfe/nix-mcp-servers` — considered but not used (simple package
  repo, no module system).
- jackpkgs `modules/flake-parts/python.nix` — canonical module pattern
  followed here.

---

## Decision

### 1. New flake-parts module: `modules/flake-parts/opencode.nix`

A new jackpkgs flake-parts `perSystem` module is added at
`modules/flake-parts/opencode.nix`. It MUST follow the existing jackpkgs
module pattern: outer function `{jackpkgsInputs}: { inputs, config, lib, ... }:`,
top-level `jackpkgs.opencode.enable` option, and per-system options declared
via `mkDeferredModuleOption`.

### 2. `mcp-servers-nix` added as a jackpkgs input

`inputs.mcp-servers-nix.url = "github:natsukium/mcp-servers-nix"` is added to
`jackpkgs/flake.nix` with `inputs.nixpkgs.follows = "nixpkgs"`. The module
closure accesses it via `jackpkgsInputs.mcp-servers-nix`. Consumers of the
jackpkgs flake module do NOT need to add this input themselves.

### 3. Module options

#### Top-level (non-perSystem)

```
jackpkgs.opencode.enable  — bool, default false
```

#### Per-system (`perSystem.jackpkgs.opencode.*`)

**MCP server typed options** — `jackpkgs.opencode.mcp.<server>.*`:

| Server | Type | Key options |
|--------|------|-------------|
| `time` | local (Python, mcp-servers-nix) | `enable`, `timezone` (default `"America/Chicago"`) |
| `serena` | local (Python, mcp-servers-nix) | `enable`, `context` (enum or null), `extraPackages` |
| `github` | remote by default | `enable`, `remote` (bool, default `true`), `tokenEnvVar` (default `"GITHUB_TOKEN"`) |
| `context7` | remote | `enable`, `apiKeyEnvVar` (default `"CONTEXT7_API_KEY"`, nullable) |
| `jujutsu` | local (npx) | `enable` |
| `claude-context` | local (npx) | `enable` |

Additional servers can be added to `mcp.extra` as a freeform `attrsOf anything`
that is merged directly into the generated `mcp` section.

**Freeform passthrough**:

```
jackpkgs.opencode.settings  — attrsOf anything, default {}
```

This is merged last (after the generated `mcp` section) and wins over typed
options where keys overlap. It carries provider configs, keybinds, `plugin`
lists, LSP configs, agents, formatters, permissions, etc. verbatim.

**Read-only outputs**:

```
jackpkgs.opencode.configFile  — package (Nix store path to opencode.json)
```

The `configFile` is also published as `packages.opencode-config`.

### 4. Config generation strategy

For **Nix-packaged servers** (`time`, `serena`, `github` local mode):
`mcp-servers-nix.lib.mkConfig pkgs { flavor = "opencode"; ... }` is called
to build isolated derivations. This produces an opencode-format `mcp` section
with proper Nix store paths in the `command` array — no `uvx`/`npx` at
runtime.

For **remote servers** (`github` in default remote mode, `context7`):
The `mcp` entry is constructed as a plain Nix attrset:
```nix
{
  type = "remote";
  url = "https://api.githubcopilot.com/mcp";
  headers = {
    Authorization = "{env:GITHUB_TOKEN}";
    X-MCP-Toolsets = "all";
  };
  enabled = true;
}
```
The `{env:VAR_NAME}` string is passed through to the JSON literally; opencode
substitutes it at runtime. No Nix store path is involved, so no secrets leak.

For **npx-based servers** (`jujutsu`, `claude-context`):
The `command` array references `${pkgs.nodejs}/bin/npx` so the Nix-managed
Node is used. These servers are NOT isolated from a packaging perspective but
at least use a deterministic Node binary.

The final `opencode.json` is built as:
```
mcp section (from mcp-servers-nix + freeform extra)
  recursiveUpdate
settings passthrough
  |> pkgs.writeText "opencode.json" (builtins.toJSON ...)
```

### 5. Project-level use (zeus pattern)

When the module is enabled in a repo's `perSystem`:
- `packages.opencode-config` is the generated config derivation.
- `jackpkgs.shell.shellHook` (or the devShell `shellHook`) symlinks the
  config into `$PRJ_ROOT/opencode.json`:
  ```bash
  ln -sf ${config.jackpkgs.opencode.configFile} "$PRJ_ROOT/opencode.json"
  ```
  This uses `$PRJ_ROOT` from jackpkgs' `project-root` module (flake-root
  integration).

### 6. User-level use (garden pattern)

jackpkgs exposes a standalone `lib.opencode.mkConfig pkgs config` function
(analogous to `mcp-servers-nix.lib.mkConfig`) that evaluates the same option
set and returns a `configFile` path. Garden's home-manager module
(`nixfiles/home/programs/opencode.nix`) calls this function directly with the
system's `pkgs` — no perSystem output threading required.

```nix
# garden/nixfiles/home/programs/opencode.nix
{ pkgs, inputs, ... }:
let
  configFile = inputs.jackpkgs.lib.opencode.mkConfig pkgs {
    mcp.time.enable = true;
    mcp.serena = { enable = true; context = "claude-code"; };
    mcp.github.enable = true;
    mcp.context7.enable = true;
    mcp.jujutsu.enable = true;
    mcp.claude-context.enable = true;
    settings = {
      "$schema" = "https://opencode.ai/config.json";
      plugin = [ "opencode-openai-codex-auth@latest" "@tarquinen/opencode-dcp@latest" ];
      provider = { ... };
      keybinds = { ... };
    };
  };
in {
  home.file.".config/opencode/opencode.json".source = configFile;
  home.file.".config/opencode/dcp.jsonc".source = ./dcp.jsonc;
}
```

`dcp.jsonc` (the DCP plugin config) is committed as a static file alongside
the nix module at `nixfiles/home/programs/dcp.jsonc` and linked verbatim — it
uses JSONC (comments) which cannot be round-tripped through `builtins.toJSON`.

### 7. Files changed

**jackpkgs:**

| File | Change |
|------|--------|
| `flake.nix` | Add `mcp-servers-nix` input |
| `modules/flake-parts/opencode.nix` | **New** — the module |
| `modules/flake-parts/all.nix` | Add `(import ./opencode.nix {inherit jackpkgsInputs;})` |
| `modules/flake-parts/default.nix` | Add `flakeModules.opencode = import ./opencode.nix ...` |

**garden (`jmmaloney4/garden`):**

| File | Change |
|------|--------|
| `nixfiles/home/programs/opencode.nix` | **New** — HM wiring |
| `nixfiles/home/programs/dcp.jsonc` | **New** — static config |
| `nixfiles/home/programs/default.nix` | Add `./opencode.nix` import |

Note: garden's `flake.nix` does NOT need a `mcp-servers-nix` input — it is
bundled inside jackpkgs' closure.

### 8. Out of scope

- A home-manager `programs.opencode` module with full typed options is
  explicitly deferred. A tracking issue is opened in jackpkgs for consumers
  to follow and leave feedback. See Related below.
- Packaging MCP servers not already in `mcp-servers-nix` (e.g., contributing
  `jujutsu` upstream) is deferred.
- The `opencode-openai-codex-auth` plugin behavior is unchanged — it is
  passed through in `settings.plugin` verbatim. Whether the existing
  `plugins` (plural) key in the current hand-edited config actually loads
  plugins is unclear; the generated config uses `plugin` (singular) per the
  official schema.

---

## Consequences

### Benefits

- **Hermetic MCP servers**: Python and Go MCP servers use Nix derivations
  with isolated dependency closures. No `PYTHONPATH` leakage, no version
  mismatches.
- **Version-controlled config**: Both user-level and project-level opencode
  configs become reproducible Nix expressions.
- **Secret safety**: `{env:VAR}` substitution keeps tokens out of the Nix
  store. Remote server headers are never evaluated by Nix.
- **Dual use**: Same module serves both home-manager (lib function) and
  flake-parts perSystem (shellHook symlink) consumers.
- **Thin wrapper**: Low maintenance burden. The heavy lifting (packaging,
  dependency management) is delegated to `mcp-servers-nix`.
- **Upgrade path**: `settings` freeform passthrough allows any new opencode
  config option to be used immediately without waiting for typed options.

### Trade-offs

- **Two consumption APIs**: `lib.opencode.mkConfig` for HM and the perSystem
  module for projects. Slightly more surface area to document and maintain.
  Mitigated by the fact that `mcp-servers-nix` makes the same split.
- **npx servers remain impure**: `jujutsu` and `claude-context` still use
  `npx` at runtime (just with a Nix-managed Node binary). They are not fully
  hermetic. This is acceptable for now — neither is in `mcp-servers-nix` and
  contributing them is deferred.
- **`plugin` vs `plugins` breakage**: Switching from `plugins` to `plugin` in
  the generated config may surface previously-silently-broken plugin loading.
  Users should verify plugins load correctly after migration.

### Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `mcp-servers-nix` upstream changes break our API | Pin via `flake.lock`; update deliberately |
| `serena` upstream packaging lags the `mcp-servers-nix` package | `mcp.extra` escape hatch allows overriding with a custom derivation |
| `settings` freeform passthrough silently wins over typed options | Document precedence clearly; `mkMerge`/`recursiveUpdate` ordering is explicit in code |
| Garden's lite-config module system doesn't expose `inputs` to HM modules | Workaround: pass `configFile` path via `extraSpecialArgs` or use `_module.args` in the nixfiles flake |

---

## Alternatives Considered

### Alternative A — Keep using `uvx`/`npx` at runtime, fix `PYTHONPATH`

Strip `PYTHONPATH` in a wrapper script before invoking `uvx`.

- Pros: No new module needed; simple shell wrapper.
- Cons: Fragile; fights against Nix environment model; does not version-control
  the config; breaks again whenever the shell environment changes.
- Why not chosen: Does not solve the root cause and ignores the config
  management problem entirely.

### Alternative B — Use `mcp-servers-nix` flake-parts module directly

Add `mcp-servers-nix` to garden's flake and use its `flakeModule` directly,
without a jackpkgs wrapper.

- Pros: Fewer layers of indirection.
- Cons: `mcp-servers-nix` flake-parts module only supports `claude-code` and
  `vscode-workspace` flavors, not `opencode`. The `lib.mkConfig` function
  must be used for opencode regardless. A jackpkgs wrapper is still needed to
  integrate with the existing jackpkgs module pattern, shell, and project-root
  infrastructure. Also does not address the garden vs. zeus dual-use
  requirement.
- Why not chosen: Doesn't remove the need for a wrapper; only saves one layer
  at the cost of losing jackpkgs integration.

### Alternative C — Full typed NixOS-style options for all opencode config

Model every opencode config key (`provider`, `keybinds`, `lsp`, `agent`, etc.)
as typed Nix options.

- Pros: Full discoverability via `nixos-option`; type checking at eval time.
- Cons: The opencode schema is large and evolves frequently. Maintaining typed
  options for every key is a significant ongoing burden with limited payoff —
  the schema is already published at `https://opencode.ai/config.json` and
  editors can validate against it directly.
- Why not chosen: Thin wrapper with `settings` freeform passthrough achieves
  the goals at much lower cost. Can be incrementally adopted for specific
  keys if needed.

### Alternative D — Put the module in `jmmaloney4/garden` only

Keep the opencode module private to garden rather than publishing in jackpkgs.

- Pros: Faster iteration; no API stability concerns.
- Cons: Not reusable by `cavinsresearch/zeus` or other consumers. jackpkgs
  already packages dev tooling for shared use — opencode fits naturally.
- Why not chosen: Dual-use requirement (garden + zeus) requires a shared module.

### Alternative E — Use `cameronfyfe/nix-mcp-servers` instead of `natsukium/mcp-servers-nix`

Use `nix run github:cameronfyfe/nix-mcp-servers#mcp-server-time` style invocations.

- Pros: No additional flake input needed; servers runnable ad-hoc.
- Cons: No module system; no opencode config generation; `serena` is not
  packaged; invocations are still impure at runtime (they fetch from the
  internet on first run if uncached).
- Why not chosen: `natsukium/mcp-servers-nix` has broader coverage including
  `serena`, a proper module API, and `lib.mkConfig` for config generation.

---

## Implementation Plan

### Phase 1 — jackpkgs (this repo)

1. Add `mcp-servers-nix` to `flake.nix` inputs.
2. Implement `modules/flake-parts/opencode.nix`:
   - Typed MCP options for `time`, `serena`, `github`, `context7`, `jujutsu`,
     `claude-context`.
   - Freeform `settings` passthrough.
   - `configFile` read-only output (`packages.opencode-config`).
   - `shellHook` symlinking `$PRJ_ROOT/opencode.json`.
   - `lib.opencode.mkConfig` standalone function exposed on the flake.
3. Register in `all.nix` and `default.nix`.
4. Add basic `nix-unit` tests covering config generation for each server type.
5. Update `README.md` per AGENTS.md instructions.

### Phase 2 — garden (`jmmaloney4/garden`)

1. Add `nixfiles/home/programs/opencode.nix` calling
   `inputs.jackpkgs.lib.opencode.mkConfig`.
2. Add `nixfiles/home/programs/dcp.jsonc` (copy of current
   `~/.config/opencode/dcp.jsonc`).
3. Update `nixfiles/home/programs/default.nix` to import `./opencode.nix`.
4. Remove or archive the hand-edited `~/.config/opencode/opencode.json`.
5. Verify MCP servers load correctly in opencode (especially plugins after
   `plugin`/`plugins` key fix).

### Phase 3 — zeus (`cavinsresearch/zeus`)

1. Add `inputs.jackpkgs` (if not already present).
2. Import `inputs.jackpkgs.flakeModules.opencode` in the flake.
3. Configure `perSystem.jackpkgs.opencode` with repo-specific servers.
4. Verify `packages.opencode-config` and shellHook symlink work correctly.

### Rollback

- Phase 1 is additive (new module, new input). No existing consumers are
  affected. Rollback = revert the PR.
- Phase 2: restore the hand-edited `~/.config/opencode/opencode.json` from
  git history. The static `dcp.jsonc` file is safe to leave in place.
- Phase 3: remove the import and delete `opencode.json` from repo root.

---

## Related

- Tracking issue: home-manager `programs.opencode` module (to be opened)
- `natsukium/mcp-servers-nix`: https://github.com/natsukium/mcp-servers-nix
- opencode config schema: https://opencode.ai/config.json
- opencode MCP docs: https://opencode.ai/docs/mcp-servers/
- ADR-003: Python flake-parts module (canonical module pattern)

---

Author: jmmaloney4
Date: 2026-02-23
PR: (pending)
