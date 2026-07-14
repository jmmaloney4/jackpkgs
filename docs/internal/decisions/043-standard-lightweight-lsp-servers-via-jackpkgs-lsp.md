# ADR 043: Standard lightweight LSP servers via jackpkgs.lsp

## Status

Proposed

## Context

- Jack's repos run many concurrent coding-agent sessions across many git
  worktrees on the same machine.
- Per-session stdio language servers multiply memory badly in this model.
  The worst case observed in `garden`: ~12 Hermes sessions spawning dozens of
  `tsserver.js` + `typescript-language-server` wrapper processes, with macOS
  attributing ~70 GB to the parent terminal.
- The root cause is structural: each agent session spawns its own language
  servers. Switching to **lighter backends** is the highest-leverage first step
  — it reduces per-instance cost without requiring a new process-supervision
  architecture.
- The backends that matter:
  - **TypeScript:** `tsgo` (TypeScript 7 native Go compiler, `--lsp` mode)
    drops RSS from ~3 GB to ~70–300 MB per instance. No Node wrapper.
  - **Python:** `ty server` (Astral, Rust-based) is 10–100× faster than
    pyright with fine-grained incrementality. Pair with `ruff server` for
    lint/format.
  - **Nix:** `nil` or `nixd` — already lightweight.
  - **Rust:** `rust-analyzer` — already the standard, good shared-cache story.
  - **YAML / Bash:** `yaml-language-server`, `bash-language-server` — cheap.
- This is a cross-repo problem. Every jackpkgs-based repo that runs agent
  sessions faces the same per-instance LSP cost. Standardizing the backends and
  making them available in devshells belongs in `jackpkgs`, not in each repo.

### Evidence from garden

- `garden` pins `typescript` `6.0.3` with 37 `tsconfig*.json` files and dozens
  of Python projects.
- Live investigation showed per-session `tsserver` multiplication consuming
  ~70 GB attributed memory across ~12 concurrent sessions.
- Immediate mitigation was to disable Hermes's built-in LSP entirely
  (`lsp.enabled: false`). This works but sacrifices post-write diagnostics.

### Related prior art in jackpkgs

- ADR 034 (devshell composition contract) — `jackpkgs` standardizes shared
  developer-environment behavior across repos.
- ADR 040 (Node workspace runtime convergence) — cross-repo language-tooling
  convergence belongs in `jackpkgs`.
- ADR 041 (Python monorepo type-check path derivation) — same pattern.
- Existing modules `python.nix`, `nodejs.nix`, `pulumi.nix`, `devshell.nix`
  provide the integration surface.

## Decision

- `jackpkgs` MUST provide a `jackpkgs.lsp` flake-parts module that installs
  standard lightweight language servers into the devshell.
- The module MUST auto-select which servers to install based on which other
  `jackpkgs` modules are enabled — no manual per-repo LSP configuration needed.
- The module SHOULD allow explicit overrides for repos that want different
  backends.
- The module MUST NOT manage process lifecycle, supervise daemons, or implement
  attach/detach logic. It installs binaries and provides configuration guidance.
  That is intentionally out of scope for this ADR.
- `jackpkgs` SHOULD package `tsgo` and `ty` in its overlay if they are not yet
  available in nixpkgs.

### Auto-selection rules

| jackpkgs module enabled | LSP server installed   | Notes                                                                              |
| ----------------------- | ---------------------- | ---------------------------------------------------------------------------------- |
| `jackpkgs.python`       | `ty` + `ruff`          | `ty` for semantics, `ruff` for lint/format                                         |
| `jackpkgs.nodejs`       | `tsgo`                 | Native Go TS LSP; falls back to `typescript-language-server` if `tsgo` unavailable |
| `jackpkgs.pulumi`       | `tsgo`                 | Pulumi projects are TS-heavy                                                       |
| (always, Nix repo)      | `nil`                  | Lightweight Nix LSP                                                                |
| (always)                | `yaml-language-server` | Cheap, useful for Helm/Pulumi/K8s YAML                                             |
| (always)                | `bash-language-server` | Cheap, useful for shell scripts                                                    |
| Cargo.toml present      | `rust-analyzer`        | Already in nixpkgs                                                                 |

### Scope

In scope:

- Installing the right LSP binaries in devshells
- Packaging `tsgo` and `ty` in the jackpkgs overlay if needed
- Configuration guidance for editors and agent harnesses
- Allowing per-repo override of backend selection

Out of scope:

- Process supervision / shared LSP daemons
- Worktree attach/detach lifecycle management
- Cross-machine or network-distributed semantic services
- Hermes daemon-mode architecture

## Consequences

### Benefits

- Every jackpkgs devshell gets the right lightweight LSPs automatically.
- Switching from `tsserver` to `tsgo` and from `pyright` to `ty` reduces
  per-session memory by 10–40× without any process-supervision complexity.
- Repos do not need to hand-wire LSP packages or discover backends independently.
- The module is simple: it installs packages and sets env vars. No daemon, no
  state, no restart logic.
- Future shared-LSP-daemon work (if needed) can build on top of this standard
  backend selection without re-litigating which servers to use.

### Trade-offs

- Per-session multiplication still exists — each agent session still spawns its
  own LSP processes. This ADR makes each instance cheaper, not fewer instances.
- `tsgo` and `ty` are newer projects. Compatibility gaps may surface in real
  repos. The module must allow easy fallback to `typescript-language-server`
  and `pyright`.
- `tsgo` requires TypeScript 7 native tooling. Repos currently on TypeScript 6
  need validation before switching.

### Risks & Mitigations

- **Risk:** `tsgo` or `ty` has compatibility gaps in real repos.
  - **Mitigation:** module provides `lsp.typescript.backend` and
    `lsp.python.backend` options to fall back to `typescript-language-server`
    or `pyright` per repo.
- **Risk:** `tsgo` or `ty` not yet in nixpkgs.
  - **Mitigation:** package them in the jackpkgs overlay via nvfetcher or
    buildNpmPackage/buildRustPackage.
- **Risk:** Repos outside jackpkgs drift into bespoke LSP setup.
  - **Mitigation:** the module is opt-in but trivially easy to enable.

## Alternatives Considered

### Alternative A — Build a shared LSP control plane with Serena

- Pros: eliminates per-session multiplication entirely.
- Cons: significant implementation effort; Serena's worktree-mutation API is
  config-rewrite + restart, not programmatic; introduces a new local daemon to
  package, supervise, and document.
- Why not chosen now: switching to lighter backends is the higher-leverage first
  step. If per-instance cost drops enough, per-session spawning may be
  acceptable. A control plane can be layered on top later if needed.

### Alternative B — Disable LSP everywhere and rely on builds/tests only

- Pros: simplest; eliminates the immediate memory problem.
- Cons: loses semantic navigation, symbol intelligence, and fast diagnostics
  that are genuinely useful for agent workflows.
- Why not chosen: good stopgap, bad steady state.

### Alternative C — Wait for Hermes to gain daemon mode

- Pros: solves per-session multiplication at the root for Hermes.
- Cons: blocks on upstream product direction; does not help non-Hermes tools.
- Why not chosen: too slow and too Hermes-specific.

### Alternative D — Per-repo ad hoc LSP installation

- Pros: fastest to implement inside one repo.
- Cons: duplicated across repos; divergent backends and config.
- Why not chosen: already a cross-repo problem.

## Implementation Plan

### Phase 1 — Package missing LSPs in jackpkgs overlay

- Package `tsgo` (`@typescript/native-preview`) via `buildNpmPackage` or
  prebuilt binary fetch.
- Package `ty` via `buildRustPackage` or prebuilt binary fetch from
  `astral-sh/ty` GitHub releases.
- Verify `nil`, `rust-analyzer`, `yaml-language-server`,
  `bash-language-server` are already in nixpkgs (they are).

### Phase 2 — Add `jackpkgs.lsp` flake-parts module

- Create `modules/flake-parts/lsp.nix`.
- Register in `modules/flake-parts/all.nix` and `modules/flake-parts/default.nix`.
- Implement auto-selection logic based on `config.jackpkgs.python.enable`,
  `config.jackpkgs.nodejs.enable`, `config.jackpkgs.pulumi.enable`.
- Add `jackpkgs.lsp.packages` to inject into `devshell.nix` composition.
- Add backend override options.

### Phase 3 — Editor and agent configuration guidance

- Document how to configure VS Code, Neovim, Helix to use the devshell LSPs.
- Document how to configure Hermes `~/.hermes/config.yaml` lsp section.
- Document how other agent harnesses (Claude Code, Codex) can discover and use
  the standard LSPs.

### Phase 4 — Pilot in garden

- Enable `jackpkgs.lsp` in `garden`.
- Validate `tsgo` and `ty` compatibility on real projects.
- Measure per-session memory improvement.
- If successful, enable in `zeus`, `yard`, and other active repos.

### Rollout / rollback

- Opt-in per repo via `jackpkgs.lsp.enable`.
- If `tsgo` or `ty` has issues, set backend override to fall back.
- Rollback: disable the module; devshell reverts to no LSP packages.

## Related

- Garden investigation: `docs/internal/investigations/2026-07-09-hermes-lsp-memory-multiplication.md`
- ADR 034: devshell composition contract
- ADR 040: Node workspace runtime convergence
- ADR 041: Python monorepo type-check path derivation
- `tsgo`: `@typescript/native-preview` (TypeScript 7 native Go compiler)
- `ty`: `astral-sh/ty` (Rust-based Python type checker + LSP)

______________________________________________________________________

Author: Arthur
Date: 2026-07-10
PR: #<pending>

## Appendix A: `jackpkgs.lsp` module shape

### Options

```nix
jackpkgs.lsp = {
  enable = mkEnableOption "jackpkgs-lsp (standard lightweight LSP servers)" // { default = false; };

  # Backend selection — defaults follow auto-selection rules
  typescript.backend = mkOption {
    type = types.enum [ "tsgo" "typescript-language-server" "none" ];
    default = "tsgo";  # falls back to typescript-language-server if tsgo missing
    description = "TypeScript/JavaScript LSP backend.";
  };

  python.backend = mkOption {
    type = types.enum [ "ty" "pyright" "none" ];
    default = "ty";
    description = "Python semantic LSP backend.";
  };

  python.lintBackend = mkOption {
    type = types.enum [ "ruff" "none" ];
    default = "ruff";
    description = "Python lint/format LSP backend.";
  };

  nix.backend = mkOption {
    type = types.enum [ "nil" "nixd" "none" ];
    default = "nil";
    description = "Nix LSP backend.";
  };

  rust.enable = mkEnableOption "rust-analyzer" // { default = false; };

  # Explicit extras (for repos that want servers not auto-selected)
  extraPackages = mkOption {
    type = types.listOf types.package;
    default = [];
    description = "Additional LSP packages to include in the devshell.";
  };
};
```

### Auto-selection logic

The module computes the package list from other enabled modules:

```nix
lspPackages =
  # TypeScript — installed when nodejs or pulumi is enabled
  lib.optionals (cfg.typescript.backend != "none" && (nodejsEnabled || pulumiEnabled))
    (if cfg.typescript.backend == "tsgo" then [ pkgs.tsgo ]
     else [ pkgs.typescript-language-server pkgs.typescript ])
  # Python semantic — installed when python is enabled
  ++ lib.optionals (cfg.python.backend != "none" && pythonEnabled)
    (if cfg.python.backend == "ty" then [ pkgs.ty ] else [ pkgs.pyright ])
  # Python lint/format — installed when python is enabled
  ++ lib.optionals (cfg.python.lintBackend != "none" && pythonEnabled)
    (if cfg.python.lintBackend == "ruff" then [ pkgs.ruff ] else [])
  # Nix — always installed (jackpkgs repos are Nix repos)
  ++ lib.optionals (cfg.nix.backend != "none")
    (if cfg.nix.backend == "nil" then [ pkgs.nil ] else [ pkgs.nixd ])
  # YAML — always
  ++ [ pkgs.yaml-language-server ]
  # Bash — always
  ++ [ pkgs.bash-language-server ]
  # Rust — opt-in because repo-root path probing is brittle at evaluation time
  ++ lib.optionals cfg.rust.enable
    [ pkgs.rust-analyzer ]
  # Explicit extras
  ++ cfg.extraPackages;
```

### Devshell integration

The module injects `lspPackages` into the devshell via the existing
`jackpkgs.shell.packages` composition surface (ADR 034). No separate shellHook
needed — the binaries just need to be on `PATH`.

### Module registration

In `modules/flake-parts/all.nix`:

```nix
(import ./lsp.nix { inherit jackpkgsInputs; })
```

In `modules/flake-parts/default.nix`:

```nix
lsp = import ./lsp.nix { inherit jackpkgsInputs; };
```

### Overlay additions

If `tsgo` and `ty` are not yet in nixpkgs, add to `overlay.nix`:

```nix
tsgo = super.buildNpmPackage {
  pname = "tsgo";
  version = "...";
  src = nvfetcherSources.tsgo.src;
  npmDepsHash = "...";
  # ...
};

ty = super.buildRustPackage {
  pname = "ty";
  version = "...";
  src = nvfetcherSources.ty.src;
  cargoSha256 = "...";
  # ...
};
```

Or fetch prebuilt binaries from GitHub releases if the build is expensive.

## Appendix B: Editor and agent configuration guidance

### VS Code

Install the relevant extensions and point them at the devshell binaries:

```jsonc
// .vscode/settings.json (repo-local)
{
  "typescript.tsdk": "${env:DEVSHELL_PREFIX}/lib/node_modules/typescript/lib",
  "typescript.enablePromptUseWorkspaceTsdk": true,
  // Requires the Astral "ty" VS Code extension once available;
  // until then, Pylance remains the default Python LSP in VS Code.
  "nix.enableLanguageServer": true,
  "nix.serverPath": "nil",
  "yaml.languageServer.path": "yaml-language-server",
  "bash.lsp.path": "bash-language-server"
}
```

For `tsgo`, use the `@typescript/native-preview` extension and set:

```jsonc
{
  "typescript.tsdk": null,
  "typescript.tsgo.path": "tsgo"
}
```

### Neovim

With `nvim-lspconfig`:

```lua
-- TypeScript via tsgo
require'lspconfig'.tsgo.setup{}  -- when tsgo LSP config is available

-- Python via ty
require'lspconfig'.ty.setup{}    -- when ty LSP config is available

-- Python lint/format via ruff
require'lspconfig'.ruff.setup{}

-- Nix
require'lspconfig'.nil_ls.setup{}

-- YAML
require'lspconfig'.yamlls.setup{}

-- Bash
require'lspconfig'.bashls.setup{}

-- Rust
require'lspconfig'.rust_analyzer.setup{}
```

Note: `tsgo` and `ty` LSP configs may not yet exist in `nvim-lspconfig`.
If not, configure manually via `vim.lsp.start()` with the binary on `PATH`.

### Helix

Helix auto-discovers LSP binaries on `PATH` via `languages.toml`:

```toml
# .helix/languages.toml (repo-local)
[[language]]
name = "typescript"
language-servers = ["tsgo"]

[language-server.tsgo]
command = "tsgo"
args = ["--lsp"]

[[language]]
name = "python"
language-servers = ["ty", "ruff"]

[language-server.ty]
command = "ty"
args = ["server"]

[language-server.ruff]
command = "ruff"
args = ["server"]

[[language]]
name = "nix"
language-servers = ["nil"]

[language-server.nil]
command = "nil"
```

### Hermes Agent

In `~/.hermes/config.yaml`:

```yaml
lsp:
  enabled: true
  install_strategy: auto
  servers:
    typescript:
      command: tsgo
      args: ["--lsp"]
    python:
      command: ty
      args: ["server"]
    nix:
      command: nil
      args: []
  wait_mode: document
  wait_timeout: 5.0
```

When `jackpkgs.lsp` is enabled and the devshell is active, Hermes will find
`tsgo`, `ty`, and `nil` on `PATH` and use them instead of its bundled
`typescript-language-server` and `pyright`.

If `tsgo` or `ty` has compatibility issues, fall back:

```yaml
lsp:
  enabled: true
  servers:
    typescript:
      command: typescript-language-server
      args: ["--stdio"]
    python:
      command: pyright-langserver
      args: ["--stdio"]
```

### Claude Code / Codex / other agent harnesses

Most agent harnesses that support LSP do so via stdio. The standard pattern:

1. Ensure the devshell is active (direnv or `nix develop`).
2. Verify the LSP binary is on `PATH`: `which tsgo`, `which ty`, `which nil`.
3. Configure the harness to spawn the binary with the right `--lsp` / `server`
   / `--stdio` flag.
4. If the harness does not support per-language LSP configuration, it will
   typically auto-discover binaries on `PATH`. The `jackpkgs.lsp` module
   ensures the right binaries are there.

### Worktree considerations

Since `jackpkgs.lsp` only installs binaries (no daemon, no state), worktrees
work naturally:

- Each worktree has its own devshell (via direnv or `nix develop`).
- The devshell includes the same LSP binaries (from the shared Nix store).
- Each agent session in a worktree spawns its own LSP process, but the binary
  itself is shared (Nix store hardlinks).
- Per-instance memory is reduced because the backends are lighter.
- No cross-worktree state sharing is needed for correctness.
