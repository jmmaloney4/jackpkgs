# AGENTS: README maintenance

Keep `README.md` flake-only and accurate. Update it when anything changes that users consume.

- Scope: flake-only (packages, overlay, `inputs.jackpkgs.flakeModules`, templates). No legacy/Home Manager/NixOS module examples.
- Update when: packages added/removed; overlay behavior changes; flake-parts modules added/renamed/options change; templates change; `flake.nix` inputs/examples change.
- How: skim `flake.nix`, `modules/flake-parts/**`, `templates/**` and ensure README has:
  - Input snippet to add the flake
  - Package usage (via `jackpkgs.packages.${system}`) and overlay example
  - Modules list (`default`, `fmt`, `just`, `pre-commit`, `shell`) + minimal import examples
  - Notable constraints (e.g., `roon-server` is x86_64-linux only)
  - Available templates
- Style: short, copy‑pasteable snippets; consistent headings; bullets over verbosity.
- Commit: Conventional Commit, docs-only (e.g., `docs(readme): keep flake-only docs up to date`).
