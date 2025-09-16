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

- `default` — imports all modules below.
- `fmt` — treefmt integration (Alejandra, Biome, Ruff, Rustfmt, Yamlfmt, etc.).
- `just` — just-flake integration with curated recipes (direnv, infra, python, git, nix).
- `pre-commit` — pre-commit-hooks (treefmt + nbstripout for `.ipynb`).
- `shell` — shared dev shell output to include via `inputsFrom`.
- `pulumi` — emits a `pulumi` devShell fragment (Pulumi CLI) for inclusion via `inputsFrom`.

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
    inputs.jackpkgs.flakeModules.fmt
    inputs.jackpkgs.flakeModules.just
    inputs.jackpkgs.flakeModules.pre-commit
    inputs.jackpkgs.flakeModules.shell
    inputs.jackpkgs.flakeModules.pulumi
  ];
}
```

### Module reference (concise)

- fmt (`modules/flake-parts/fmt.nix`)
  - Enables treefmt and sets `formatter = config.treefmt.build.wrapper`.
  - Options under `jackpkgs.fmt`:
    - `treefmtPackage` (package, default `pkgs.treefmt`)
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

- pre-commit (`modules/flake-parts/pre-commit.nix`)
  - Enables pre-commit with `treefmt` and `nbstripout` for `.ipynb`.
  - Options under `jackpkgs.pre-commit`:
    - `treefmtPackage` (defaults to `config.treefmt.build.wrapper`)
    - `nbstripoutPackage` (default `pkgs.nbstripout`)

- shell (`modules/flake-parts/devshell.nix`)
  - Produces a composable dev shell output: `config.jackpkgs.outputs.devShell`.
  - The shell aggregates dev environments from `just-flake`, `flake-root`, `pre-commit`, and `treefmt`.
  - Conditionally includes `pulumi` devShell fragment when `jackpkgs.pulumi.enable` is true.

- pulumi (`modules/flake-parts/pulumi.nix`)
  - Provides Pulumi CLI in a devShell fragment: `config.jackpkgs.outputs.pulumiDevShell`.
  - Options under `jackpkgs.pulumi`:
    - `enable` (bool, default `true`)

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
- `nbstripout` — Strip outputs from Jupyter notebooks
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

