# jackpkgs (flake)

Jack's Nix flake providing packages, an overlay, and reusable flake-parts modules.

## TL;DR

- Add as a flake input: `jackpkgs = "github:jmmaloney4/jackpkgs"`.
- Use packages via `jackpkgs.packages.${system}` or by enabling the overlay in your `nixpkgs`.
- Import flake-parts modules from `inputs.jackpkgs.flakeModules` (default or à la carte).

---

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

---

## Flake-parts modules

This flake exposes reusable flake-parts modules under `inputs.jackpkgs.flakeModules` sourced from `modules/flake-parts/`:

- `default` — imports all modules below (including `pkgs`).
- `pkgs` — provides `jackpkgs.pkgs` option for consumer-provided overlayed nixpkgs. Required for à la carte imports when using `jackpkgs.pkgs`.
- `fmt` — treefmt integration (Alejandra, Biome, Ruff, Rustfmt, Yamlfmt, etc.).
- `just` — just-flake integration with curated recipes (direnv, infra, python, git, nix).
- `pre-commit` — pre-commit hooks (treefmt + nbstripout for `.ipynb` + mypy; picks up `jackpkgs.python.environments.default` automatically when defined).
 - `shell` — shared dev shell output to include via `inputsFrom`.
 - `checks` — CI checks for Python (pytest/mypy/ruff) and TypeScript (tsc, vitest).
 - `nodejs` — builds `node_modules` via `buildNpmPackage` and exposes a Node.js devShell fragment.
- `pulumi` — emits a `pulumi` devShell fragment (Pulumi CLI) for inclusion via `inputsFrom`.
- `quarto` — emits a Quarto devShell fragment, with configurable Quarto and Python packages.
- `nodejs` — builds `node_modules` via `buildNpmPackage` and exposes a Node.js devShell fragment.
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
  - Enables pre-commit with `treefmt`, `nbstripout` for `.ipynb`, and `mypy`.
  - **Important:** For the mypy hook to work, `mypy` must be available in the Python environment. See [Common Patterns: Dev Tools with Pre-commit](#common-patterns-dev-tools-with-pre-commit) below.
  - Options under `jackpkgs.pre-commit`:
    - `treefmtPackage` (defaults to `config.treefmt.build.wrapper`)
    - `nbstripoutPackage` (default `config.jackpkgs.pkgs.nbstripout`)
    - `mypyPackage` (defaults to the package produced by `jackpkgs.python.environments.default` when defined—editable or not—otherwise `config.jackpkgs.pkgs.mypy`)

- checks (`modules/flake-parts/checks.nix`)
  - Adds CI checks for Python (pytest/mypy/ruff) and TypeScript (tsc).
  - **Python CI Environment Selection:**
    - Automatically selects a suitable environment for CI checks (non-editable with dependency groups).
    - Priority order:
      1. Use `dev` environment if it's non-editable and has `includeGroups = true`
      2. Use any non-editable environment with `includeGroups = true`
      3. Auto-create a temporary CI environment with all dependency groups enabled
    - Editable environments are never used for CI (they can't be used in pure Nix builds).
  - Options under `jackpkgs.checks` (selected):
    - `enable` (bool, default auto-enabled with Python/Pulumi/Node.js)
    - `python.enable`, `python.pytest.enable`, `python.mypy.enable`, `python.ruff.enable`
    - `typescript.enable`, `typescript.tsc.packages`, `typescript.tsc.extraArgs`

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
   - Builds `node_modules` using `buildNpmPackage` and exposes `jackpkgs.outputs.nodeModules`.
   - Provides a Node.js devShell fragment: `jackpkgs.outputs.nodejsDevShell`.
   - Options under `jackpkgs.nodejs`:
     - `enable` (bool, default `false`)
     - `version` (enum: 18/20/22, default `22`)
     - `projectRoot` (path, default `config.jackpkgs.projectRoot`)
     - `importNpmLockOptions` (attrs, default `{}`) - Additional options passed to `importNpmLock` for private registries

   **Hermetic Constraints (ADR-022)**
   The `nodejs` module builds `node_modules` hermetically in a pure Nix sandbox (no network access). This ensures reproducible builds but requires that all dependencies are available through `importNpmLock`'s prefetch mechanism.

   **Supported dependency forms:**
   - ✅ npm registry packages (public or configured private registries)
   - ✅ npm workspaces (via `package.json` `workspaces` field)

   **Unsupported dependency forms:**
   - ❌ Git dependencies (`git+https://`, `git+ssh://`, `github:`)
   - ❌ File dependencies (`file:../path`, `link:../path`)
   - ❌ Dependencies without `resolved` or `integrity` fields
   - ❌ Private registries without proper fetch configuration

   **Troubleshooting `ENOTCACHED` errors:**

   If you encounter:
   ```
   npm error code ENOTCACHED
   request to https://registry.npmjs.org/<pkg> failed: cache mode is 'only-if-cached' but no cached response is available
   ```

   The nodejs module will now fail fast during Nix evaluation with a clear error pointing to problematic dependencies. Common fixes:

   1. **Git dependencies:** Replace with npm registry version or publish a private registry package
   2. **File dependencies:** Use npm workspaces or publish to registry
   3. **Missing integrity:** Regenerate lockfile with `npm install`
   4. **Private registry:** Configure `importNpmLockOptions.fetcherOpts`

   **Private registry example:**

   ```nix
   jackpkgs.nodejs = {
     enable = true;
     importNpmLockOptions = {
       fetcherOpts = {
         "node_modules/@myorg" = {
           curlOptsList = [ 
             "--header" "Authorization: Bearer ''${NPM_TOKEN}"
           ];
         };
       };
     };
   };
   ```

   See ADR-022 for full design rationale and implementation details.

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

When using the pre-commit module with Python projects, the mypy hook requires `mypy` to be available in your Python environment. Here's how to set this up properly:

**Step 1: Add dev tools to your `pyproject.toml`**

Define development dependencies using PEP 735 dependency groups:

```toml
[dependency-groups]
dev = [
    "mypy>=1.11",
    "pytest>=8.0",
    "ruff>=0.1.0",
    "types-requests",  # type stubs for better mypy coverage
]
```

**Step 2: Configure your environment with `includeGroups = true`**

The key is to ensure your `default` environment (used by pre-commit) includes dependency groups:

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

Or with separate environments for dev and production (requires `mypyPackage` override):

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
      editable = true;
      # Dev dependencies automatically included (includeGroups defaults to true for editable)
    };
  };
};

# IMPORTANT: Override mypyPackage to use the dev environment for pre-commit hooks
# Without this, the mypy hook will fail because 'default' lacks mypy
perSystem = { config, ... }: {
  jackpkgs.pre-commit.mypyPackage = config.jackpkgs.outputs.pythonEnvironments.dev;
};
```

**Why is this necessary?**

- The pre-commit module uses `pythonDefaultEnv` for the mypy hook
- Non-editable environments default to `includeGroups = false` (production-only)
- You must explicitly set `includeGroups = true` to include dev dependencies
- Alternatively, use an editable environment which defaults to `includeGroups = true`

**Environment Pattern Summary:**

| Pattern | `editable` | `includeGroups` | Pre-commit works? |
|---------|------------|-----------------|-------------------|
| Production | `false` | `false` (default) | No (no mypy) |
| Development | `true` | `true` (default) | Yes (if used as default) |
| CI/Pre-commit | `false` | `true` (explicit) | Yes |
| Separate prod + dev | `default`: prod, `dev`: editable | — | Requires `mypyPackage` override |

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

---

## Packages available

- `csharpier` — C# formatter
- `docfx` — .NET docs generator
- `epub2tts` — EPUB → TTS
- `lean` — Lean theorem prover
- `roon-server` — Roon server (x86_64-linux only)
- `tod` — Todoist CLI

Build from CLI (examples):

```bash
# build a package from this flake
nix build github:jmmaloney4/jackpkgs#tod

# or from within your project if exposed via packages
nix build .#tod
```

---

## Template(s)

A `just-flake` template is available:

```bash
nix flake init -t github:jmmaloney4/jackpkgs#just
# or
nix flake new myproj -t github:jmmaloney4/jackpkgs#just
```

---

## License

See `LICENSE`.
