# AGENTS: jackpkgs

## Repository quick map

- `flake.nix`: public flake outputs and inputs; start here when modifying exposed packages or modules.
- `modules/flake-parts/`: reusable flake-parts modules for shells, formatting, pre-commit, just, Python, and other integrations.
- `modules/nixos/`, `modules/nix-darwin/`, `modules/home-manager/`: system/home module outputs (see ADR-051).
- `templates/`: starter templates; check the corresponding README section when changing them.
- `README.md`: consumer-facing flake documentation and usage examples; keep its established flake-only contract.

Explore the relevant module/output rather than inventorying the whole repository. For Cursor-hosted agents, read `.cursor/CLOUD.md` once before setup/testing; it supplements these rules.

## README maintenance

Keep `README.md` flake-only and accurate. Update it when anything changes that users consume.

- Scope: flake-only (packages, overlay, `inputs.jackpkgs.flakeModules`, module outputs `inputs.jackpkgs.{nixosModules,darwinModules,homeModules}`, templates). Home Manager/NixOS/darwin modules ARE in scope since ADR-051; the legacy `pkgs.homeManagerModules` overlay path stays undocumented.
- Update when: packages added/removed; overlay behavior changes; flake-parts modules added/renamed/options change; NixOS/darwin/HM modules added/renamed (update the module-outputs section); templates change; `flake.nix` inputs/examples change.
- How: skim `flake.nix`, `modules/flake-parts/**`, `modules/{nixos,nix-darwin,home-manager}/**`, `templates/**` and ensure README has:
  - Input snippet to add the flake
  - Package usage (via `jackpkgs.packages.${system}`) and overlay example
  - Modules list (`default`, `fmt`, `just`, `pre-commit`, `shell`) + minimal import examples
  - NixOS/darwin/HM module-outputs import examples (see ADR-051 for the conventions)
  - Notable constraints (if any)
  - Available templates
- Style: short, copy‑pasteable snippets; consistent headings; bullets over verbosity.
- Commit: Conventional Commit, docs-only (e.g., `docs(readme): keep flake-only docs up to date`).
