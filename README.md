# jackpkgs (flake)

Jack's Nix flake providing packages, an overlay, and reusable flake-parts modules.

## TL;DR

- Add as a flake input: `jackpkgs = "github:jmmaloney4/jackpkgs"`.
- Use packages via `jackpkgs.packages.${system}` or by enabling the overlay in your `nixpkgs`.
- Import flake-parts modules from `inputs.jackpkgs.flakeModules` (default or à la carte).

______________________________________________________________________

## Add as a flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # or your chosen channel
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
  };
}
```

## Use packages (flake-only)

- Directly reference packages:

```nix
{
  outputs = { self, nixpkgs, jackpkgs, ... }:
  let
    system = "x86_64-darwin"; # or x86_64-linux, aarch64-linux, etc.
  in {
    packages.${system} = {
      inherit (jackpkgs.packages.${system}) csharpier docfx tod; # example
    };

    # Or build one-off from CLI:
    # nix build .#csharpier
    # nix build github:jmmaloney4/jackpkgs#docfx
  };
}
```

- Via overlay (for seamless `pkgs.<name>`):

```nix
{
  outputs = { self, nixpkgs, jackpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ jackpkgs.overlays.default ];
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.csharpier pkgs.docfx pkgs.tod ];
    };
  };
}
```

Notes:

- `roon-server` is packaged for `x86_64-linux` only.
- `roon-server` is unfree; enable unfree in your `nixpkgs` config when consuming it:

```nix
{
  nixpkgs.config.allowUnfree = true;
}
```

- `openchamber` defaults to `opencode` from `numtide/llm-agents.nix`.
- Override `openchamber`'s `opencode` dependency with:

```nix
let
  openchamber = jackpkgs.packages.${system}.openchamber.override {
    opencode = myOpencode;
  };
in {
  packages.${system}.openchamber = openchamber;
}
```

______________________________________________________________________

## Flake-parts modules

This flake exposes reusable flake-parts modules under `inputs.jackpkgs.flakeModules` sourced from `modules/flake-parts/`:

- `default` — imports all modules below (including `pkgs`).
- `pkgs` — provides `jackpkgs.pkgs` option for consumer-provided overlayed nixpkgs. Required for à la carte imports when using `jackpkgs.pkgs`.
- `fmt` — treefmt integration (Alejandra, Biome, Ruff, Rustfmt, Yamlfmt, etc.).
- `just` — just-flake integration with curated recipes (direnv, infra, python, git, nix).
- `pre-commit` — pre-commit hooks (treefmt + nbstripout for `.ipynb` + Python gates + tsc + vitest); Python tool packages default to the same dev-tools env selection as CI checks.
- `shell` — shared dev shell output to include via `inputsFrom`.
- `checks` — CI checks for Python (pytest/mypy/ruff, optional numpydoc), TypeScript (tsc), and JavaScript (vitest).
- `nodejs` — builds `node_modules` via `fetchPnpmDeps/pnpmConfigHook` and exposes a Node.js devShell fragment.
- `pulumi` — emits a `pulumi` devShell fragment (Pulumi CLI) for inclusion via `inputsFrom`.
- `quarto` — emits a Quarto devShell fragment, with configurable Quarto and Python packages.
- `python` — opinionated Python environments via uv2nix; exposes env packages and a devShell fragment.

### Import (one-liner: everything)

```nix
flake-parts.lib.mkFlake { inherit inputs; } {
  systems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];
  imports = [ inputs.jackpkgs.flakeModules.default ];
}
```

### Import (à la carte)

```nix
flake-parts.lib.mkFlake { inherit inputs; } {
  systems = import inputs.systems;
  imports = [
    inputs.jackpkgs.flakeModules.pkgs  # Required when using jackpkgs.pkgs with overlayed nixpkgs
    inputs.jackpkgs.flakeModules.fmt
    inputs.jackpkgs.flakeModules.just
    inputs.jackpkgs.flakeModules.pre-commit
    inputs.jackpkgs.flakeModules.shell
    inputs.jackpkgs.flakeModules.pulumi
    inputs.jackpkgs.flakeModules.quarto
    inputs.jackpkgs.flakeModules.python
  ];
}
```

Note: When importing modules à la carte, include `flakeModules.pkgs` if you want to set `jackpkgs.pkgs` to propagate overlayed nixpkgs. The `default` module includes it automatically.

### Using overlayed nixpkgs

When you set `_module.args.pkgs` to provide an overlayed nixpkgs, jackpkgs modules won't see those overlays by default (due to module evaluation order). To propagate your overlays to all jackpkgs package defaults, also set `jackpkgs.pkgs`:

```nix
perSystem = { system, ... }: let
  overlayedPkgs = import inputs.nixpkgs {
    inherit system;
    overlays = [
      (self: super: {
        deno = super.deno.overrideAttrs (_: { doCheck = false; });
      })
    ];
  };
in {
  _module.args.pkgs = overlayedPkgs;
  jackpkgs.pkgs = overlayedPkgs;  # Propagates to all jackpkgs module defaults
};
```

### Module reference (concise)

- pkgs (`modules/flake-parts/pkgs.nix`)

  - Exposes `jackpkgs.pkgs` (per-system, type `pkgs`, default `pkgs`).
  - Modules with package defaults use `config.jackpkgs.pkgs`.
  - Set this to your overlayed nixpkgs to propagate overlays to all jackpkgs package defaults.

- core (`modules/flake-parts/project-root.nix`)

  - Exposes `jackpkgs.projectRoot` (path, default `inputs.self.outPath`).
  - Other modules resolve relative project files against this path.

- fmt (`modules/flake-parts/fmt.nix`)

  - Enables treefmt and sets `formatter = config.treefmt.build.wrapper`.
  - Options under `jackpkgs.fmt`:
    - `treefmtPackage` (package, default `config.jackpkgs.pkgs.treefmt`)
    - `projectRootFile` (str, default `config.flake-root.projectRootFile`)
    - `excludes` (list of str, default `["**/node_modules/**" "**/dist/**"]`)
  - Enables formatters: Alejandra (Nix), Biome (JS/TS), HuJSON, latexindent, Ruff (check + format), Rustfmt, Yamlfmt.

- just (`modules/flake-parts/just.nix`)

  - Integrates `just-flake` features; provides a generated `justfile` with:
    - direnv: `just reload` (`direnv reload`)
    - infra: `just auth` (GCloud ADC), `just new-stack <project> <stack>` (Pulumi)
    - python: `just nbstrip [<notebook>]` (strip outputs)
    - git: `just pre`, `just pre-all` (pre-commit)
    - nix: `just build-all`, `just build-all-verbose` (flake-iter)
  - Options under `jackpkgs.just` to replace tool packages if desired:
    - `direnvPackage`, `fdPackage`, `flakeIterPackage`, `googleCloudSdkPackage`, `jqPackage`, `nbstripoutPackage`, `preCommitPackage`, `pulumiPackage`
    - `pulumiBackendUrl` (nullable string)
  - Options under `jackpkgs.gcp`:
    - `iamOrg` (nullable string, default `null`) — GCP IAM organization domain for the `auth` recipe. When set, `just auth` uses `--account=$GCP_ACCOUNT_USER@<domain>` where `GCP_ACCOUNT_USER` defaults to `$USER`. Example: `iamOrg = "example.com";`

- pre-commit (`modules/flake-parts/pre-commit.nix`)

  - Enables pre-commit with `treefmt`, `nbstripout` for `.ipynb`, Python hooks (`mypy`, `ruff`, `pytest`, optional `numpydoc`), `tsc`, and `vitest`.
  - `pytest` and `vitest` hooks run at the `pre-push` stage.
  - **Important:** Python tooling hooks require dev tools in the selected Python environment. See [Common Patterns: Dev Tools with Pre-commit](#common-patterns-dev-tools-with-pre-commit) below.
  - Options under `jackpkgs.pre-commit`:
    - `enable` (bool, default `true`)
    - `treefmtPackage` (defaults to `config.treefmt.build.wrapper`)
    - `nbstripoutPackage` (default `config.jackpkgs.pkgs.nbstripout`)
    - `python.mypy.enable` (bool, default `true`)
    - `python.mypy.package` (defaults to dev-tools env selection: `dev` non-editable with `includeGroups = true` -> any non-editable env with `includeGroups = true` -> auto-created CI env with dependency groups -> `pythonDefaultEnv` -> `config.jackpkgs.pkgs.mypy`)
    - `python.mypy.extraArgs` (list of strings, default `[]`)
    - `python.ruff.enable` (bool, default `true`)
    - `python.ruff.package` (defaults to `config.jackpkgs.pre-commit.python.mypy.package`)
    - `python.ruff.extraArgs` (list of strings, default `["--no-cache"]`)
    - `python.pytest.enable` (bool, default `true`)
    - `python.pytest.package` (defaults to `config.jackpkgs.pre-commit.python.mypy.package`)
    - `python.pytest.extraArgs` (list of strings, default `[]`)
    - `python.numpydoc.enable` (bool, default `false`)
    - `python.numpydoc.package` (defaults to `config.jackpkgs.pre-commit.python.mypy.package`)
    - `python.numpydoc.extraArgs` (list of strings, default `[]`)
    - `typescript.tsc.enable` (bool, default `true`)
    - `typescript.tsc.package` (defaults to `pkgs.nodePackages.typescript`)
    - `typescript.tsc.nodeModules` (nullable package, default `null` -> falls back to `jackpkgs.outputs.nodeModules`)
    - `typescript.tsc.extraArgs` (list of strings, default `[]`)
    - `javascript.vitest.enable` (bool, default `true`)
    - `javascript.vitest.package` (defaults to `pkgs.nodejs`)
    - `javascript.vitest.nodeModules` (nullable package, default `null` -> falls back to `jackpkgs.outputs.nodeModules`)
    - `javascript.vitest.extraArgs` (list of strings, default `[]`)

- checks (`modules/flake-parts/checks.nix`)

  - Adds CI checks for Python (pytest/mypy/ruff, optional numpydoc), TypeScript (tsc), and JavaScript (vitest).
  - **Python CI Environment Selection:**
    - Automatically selects a suitable environment for Python checks (non-editable with dependency groups).
    - Pre-commit Python tooling hooks use the same selection logic.
    - Priority order:
      1. Use `dev` environment if it's non-editable and has `includeGroups = true`
      2. Use any non-editable environment with `includeGroups = true`
      3. Auto-create a temporary CI environment with all dependency groups enabled
    - Editable environments are never used for CI (they can't be used in pure Nix builds).
  - Options under `jackpkgs.checks` (selected):
    - `enable` (bool, default auto-enabled with Python/Pulumi/Node.js)
    - `python.enable`, `python.pytest.enable`, `python.mypy.enable`, `python.ruff.enable`, `python.numpydoc.enable`
    - `python.pytest.extraArgs`, `python.mypy.extraArgs`, `python.ruff.extraArgs`, `python.numpydoc.extraArgs`
    - `python.mirrorPreCommit.enable` (bool, default `false`; opt-in default mirroring from `jackpkgs.pre-commit.python.*.enable`)
    - `python.mirrorPreCommit.gates` (list of `pytest|mypy|ruff|numpydoc`, default `["numpydoc"]`)
    - `typescript.enable`, `typescript.tsc.enable`, `typescript.tsc.packages`, `typescript.tsc.nodeModules`, `typescript.tsc.extraArgs`
    - `vitest.enable`, `vitest.packages`, `vitest.nodeModules`, `vitest.extraArgs`

  - By default, checks and pre-commit remain independently configurable. Enable `python.mirrorPreCommit` only when you want selected Python check gates to follow pre-commit gate toggles.

**Quality-gate parity matrix:**

| Tool | `jackpkgs.checks` | `jackpkgs.pre-commit` | Default |
| ---- | ----------------- | --------------------- | ------- |
| `mypy` | `python.mypy` | `python.mypy` | enabled |
| `ruff` | `python.ruff` | `python.ruff` | enabled |
| `pytest` | `python.pytest` | `python.pytest` (pre-push) | enabled |
| `numpydoc` | `python.numpydoc` | `python.numpydoc` | disabled |
| `tsc` | `typescript.tsc` | `typescript.tsc` | enabled |
| `vitest` | `vitest` | `javascript.vitest` (pre-push) | enabled |

- shell (`modules/flake-parts/devshell.nix`)

  - Produces a composable dev shell output: `config.jackpkgs.outputs.devShell`.
  - The shell aggregates dev environments from `just-flake`, `flake-root`, `pre-commit`, and `treefmt`.
  - Conditionally includes `pulumi` devShell fragment when `jackpkgs.pulumi.enable` is true.

- pulumi (`modules/flake-parts/pulumi.nix`)

  - Provides Pulumi CLI in a devShell fragment: `config.jackpkgs.outputs.pulumiDevShell`.
  - Provides CI devshell: `devShells.ci-pulumi` with minimal dependencies for CI environments.
  - Options under `jackpkgs.pulumi`:
    - `enable` (bool, default `true`)
    - `backendUrl` (str, required) - Pulumi backend URL
    - `secretsProvider` (str, required) - Pulumi secrets provider
    - `ci.packages` (list of packages) - Packages included in ci-pulumi devshell

- nodejs (`modules/flake-parts/nodejs.nix`)

  - Builds `node_modules` using `fetchPnpmDeps` + `pnpmConfigHook` and exposes `jackpkgs.outputs.nodeModules`.
  - Provides a Node.js devShell fragment: `jackpkgs.outputs.nodejsDevShell` with `pnpm` CLI.
  - Discovers workspace packages from `pnpm-workspace.yaml` (supports `dir/*` glob patterns; `**` recursive globs not supported).
  - **Required**: Set `jackpkgs.nodejs.pnpmDepsHash` to the FOD hash of your pnpm dependencies. Run once without it to get the expected hash from the error, then add it.
  - Options under `jackpkgs.nodejs`:
    - `enable` (bool, default `false`)
    - `version` (enum: 18/20/22, default `22`) — Node.js major version
    - `pnpmVersion` (enum: 9/10, default `10`) — pnpm major version
    - `pnpmDepsHash` (string, required when enabled) — FOD hash for `fetchPnpmDeps`
    - `projectRoot` (path, default `config.jackpkgs.projectRoot`)
  - Outputs:
    - `jackpkgs.outputs.nodeModules` — derivation containing `node_modules/`
    - `jackpkgs.outputs.pnpmDeps` — derivation containing fetched pnpm deps (for debugging/caching)
  - Example:
    ```nix
    jackpkgs.nodejs = {
      enable = true;
      version = "22";
      pnpmVersion = "10";
      pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    ```

- quarto (`modules/flake-parts/quarto.nix`)

  - Provides Quarto tooling in a devShell fragment: `config.jackpkgs.outputs.quartoDevShell`.
  - Options under `jackpkgs.quarto`:
    - `enable` (bool, default `true`)
    - `quartoPackage` (package, default `config.jackpkgs.pkgs.quarto`)
    - `pythonEnv` (package, default `config.jackpkgs.pkgs.python3Packages.python`)

- python (`modules/flake-parts/python.nix`)

  - Opinionated Python envs using uv2nix; publishes env packages and exposes workspace helpers.
  - Supports both standard projects (with `[project]`) and workspace-only repos (with `[tool.uv.workspace]` only).
  - **Environment Types:**
    - **Development (editable)**: `editable = true` — Used in devshells for local development. Source code changes are immediately reflected. Automatically includes dependency groups by default (`includeGroups` defaults to `true`). Only one editable environment is allowed per flake.
    - **CI (non-editable with groups)**: `editable = false`, `includeGroups = true` — Used for hermetic CI checks (pytest, mypy, ruff). Non-editable ensures reproducible builds. Includes all dependency groups (dev tools, type stubs, etc.). The `checks` module automatically selects or creates a CI environment.
    - **Production (non-editable without groups)**: `editable = false`, `includeGroups = false` (or `null`) — Minimal environment with only production dependencies. Suitable for deployment. Published as `packages.<env.name>`.
  - **Dependency Groups (PEP 735):**
    - This module supports **PEP 735 dependency groups only** (not PEP 621 optional-dependencies).
    - Dependency groups are **aggregated across all workspace members**: `workspace.deps.groups` includes all `[dependency-groups]` and `[tool.uv.dev-dependencies]` from the workspace root and all local member projects.
    - Define shared dev dependencies (pytest, mypy, ruff, type stubs) at the workspace root for all members to use.
    - Example `pyproject.toml` structure:
      ```toml
      [tool.uv.workspace]
      members = ["packages/*", "tools/*"]

      [dependency-groups]
      dev = ["pytest>=8.0", "mypy>=1.11", "ruff>=0.1.0"]
      test = ["pytest-cov", "types-requests"]
      ```
  - Options under `jackpkgs.python` (selected):
    - `enable` (bool, default `false`)
    - `pyprojectPath` (str, default `./pyproject.toml`)
    - `uvLockPath` (str, default `./uv.lock`)
    - `workspaceRoot` (str, default `.`)
    - `pythonPackage` (package, default `config.jackpkgs.pkgs.python312`)
    - `sourcePreference` ("wheel" | "sdist", default "wheel")
    - `setuptools.packages` (list of str)
    - `environments` (attrset of env defs: `{ name, spec, editable, editableRoot, members, passthru, includeGroups }`)
      - **`spec`**: optional — explicit dependency specification for customization (overrides all other spec options)
      - **`includeGroups`**: nullable bool (default `null`) — include all `[dependency-groups]` (PEP 735) and `[tool.uv.dev-dependencies]` from workspace members.
        - When `null` (default): follows environment intent — `true` for editable envs, `false` for non-editable envs
        - When `true`: explicitly include all dependency groups (dev tools, type stubs, etc.)
        - When `false`: explicitly exclude dependency groups (production-only)
      - **`editable`**: bool (default `false`) — create editable install with workspace members. At most one environment may have `editable = true`; automatically included in devshell.
  - Outputs:
    - Packages: non-editable envs appear under `packages.<env.name>`
    - Module args: `_module.args.pythonWorkspace` (always exposed)
    - DevShell: editable environment automatically included when defined
    - `jackpkgs.outputs.pythonEnvironments`: attrset of built env derivations keyed by `jackpkgs.python.environments`
    - `jackpkgs.outputs.pythonDefaultEnv`: derivation for `jackpkgs.python.environments.default` when present
  - Examples:
    ```nix
    # Minimal - production dependencies only
    jackpkgs.python = {
      enable = true;
      workspaceRoot = ./.;
      environments.default = {
        name = "python-prod";
        # editable = false (default)
        # includeGroups = null → defaults to false for non-editable
      };
    };

    # Development environment (editable, includes dev dependencies by default)
    jackpkgs.python = {
      enable = true;
      workspaceRoot = ./.;
      environments = {
        default.name = "python-prod";
        dev = {
          name = "python-dev";
          editable = true;  # Automatically in devshell
          # includeGroups = null → defaults to true for editable
          # Includes all [dependency-groups] from workspace members
        };
      };
    };

    # CI environment for checks (non-editable, explicitly includes dev tools)
    jackpkgs.python = {
      enable = true;
      workspaceRoot = ./.;
      environments = {
        default.name = "python-prod";
        ci = {
          name = "python-ci";
          editable = false;  # Non-editable for reproducible CI
          includeGroups = true;  # Explicitly include dev tools (pytest, mypy, ruff)
        };
      };
    };

    # Custom: editable without dev dependencies (rare use case)
    jackpkgs.python = {
      enable = true;
      workspaceRoot = ./.;
      environments = {
        dev = {
          name = "python-dev-minimal";
          editable = true;
          includeGroups = false;  # Override default: no dev dependencies
        };
      };
    };
    ```

#### Common Patterns: Dev Tools with Pre-commit

When using the pre-commit module with Python projects, Python tooling hooks require the corresponding dev tools in the selected Python environment (`mypy`, `ruff`, `pytest`; and `numpydoc` only when enabled).

**Step 1: Add dev tools to your `pyproject.toml`**

Define development dependencies using PEP 735 dependency groups:

```toml
[dependency-groups]
dev = [
    "mypy>=1.11",
    "pytest>=8.0",
    "ruff>=0.1.0",
    "types-requests",  # type stubs for better mypy coverage
    "numpydoc>=1.7",   # optional: only needed if enabling numpydoc checks/hooks
]
```

**Step 2: Configure your environment with `includeGroups = true`**

The easiest setup is a non-editable environment with dependency groups enabled:

```nix
# Simple setup: single environment with dev tools
jackpkgs.python = {
  enable = true;
  workspaceRoot = ./.;
  environments.default = {
    name = "python-default";
    includeGroups = true;  # Include dev dependencies for pre-commit hooks
  };
};
```

Or with separate environments for dev and production:

```nix
# Separate environments: editable dev + production default
jackpkgs.python = {
  enable = true;
  workspaceRoot = ./.;
  environments = {
    default = {
      name = "python-prod";
      # Production-only (includeGroups defaults to false)
    };
    dev = {
      name = "python-dev";
      includeGroups = true;
      # Non-editable + includeGroups = true is preferred for CI and pre-commit tool checks
    };
  };
};
```

**Why is this necessary?**

- Python pre-commit tooling hooks and Python CI checks share the same env selection priority
- Preferred env is non-editable with `includeGroups = true`
- Non-editable environments default to `includeGroups = false` (production-only), so set it explicitly for tooling checks
- If no matching env exists, jackpkgs auto-creates a temporary CI/check env with dependency groups

**Environment Pattern Summary:**

| Pattern | `editable` | `includeGroups` | Checks + pre-commit Python hooks |
| ------- | ---------- | --------------- | -------------------------------- |
| Production-only default | `false` | `false` (default) | No (no mypy/ruff/pytest tooling) |
| CI/pre-commit-ready | `false` | `true` | Yes |
| Separate prod + dev envs | mixed | dev env: `true` | Yes (dev env is selected) |
| No matching configured env | — | — | Yes (auto-created fallback env) |

#### Path resolution (project root)

- Core module `modules/flake-parts/project-root.nix` exposes `jackpkgs.projectRoot` (type: `path`, default `inputs.self.outPath`).
- Modules resolve relative file options (e.g., `pyprojectPath`, `uvLockPath`, `workspaceRoot`) against this path during Nix evaluation.
- To avoid Nix type errors when joining paths at eval-time, ensure:
  - `jackpkgs.projectRoot` is a Nix path (e.g., `inputs.self.outPath` or `./.`), or an absolute path converted via `builtins.toPath`.
  - Keep option values as relative strings; modules will resolve them.
- See ADR-004 for details and troubleshooting: `docs/internal/designs/004-project-root-resolution.md`.

### DevShell usage pattern

Include the shared shell in your own dev shell via `inputsFrom`:

```nix
perSystem = { pkgs, config, ... }: {
  devShells.default = pkgs.mkShell {
    inputsFrom = [
      config.jackpkgs.outputs.devShell
    ];
    packages = [ ]; # add your project-specific tools
  };
};
```

______________________________________________________________________

## Packages available

- `csharpier` — C# formatter
- `docfx` — .NET docs generator
- `epub2tts` — EPUB → TTS
- `lean` — Lean theorem prover
- `roon-server` — Roon server (x86_64-linux only, unfree)
- `openchamber` — Web and desktop interface for OpenCode AI agent
- `tod` — Todoist CLI

Build from CLI (examples):

```bash
# build a package from this flake
nix build github:jmmaloney4/jackpkgs#tod

# or from within your project if exposed via packages
nix build .#tod
```

______________________________________________________________________

## Template(s)

A `just-flake` template is available:

```bash
nix flake init -t github:jmmaloney4/jackpkgs#just
# or
nix flake new myproj -t github:jmmaloney4/jackpkgs#just
```

______________________________________________________________________

## License

See `LICENSE`.
