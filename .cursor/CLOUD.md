# Cursor Cloud: jackpkgs

These are cloud-specific pointers; follow the existing root `AGENTS.md` README and module-output rules.

## Environment and scope

- This is a Nix flake library, not an application server. Most tasks start at `flake.nix` or one file in `modules/flake-parts/`, `modules/nixos/`, `modules/nix-darwin/`, `modules/home-manager/`, or `templates/`.
- Reuse the Cursor Cloud build environment. Confirm `nix` and `just` are installed; if they are missing, report the setup blocker rather than attempting repeated system-wide installation.
- Avoid changing `flake.lock` unless the task requires an input update. Do not run host switches, deployments, or other live system mutation.

## Validation and handoff

- Prefer a targeted `nix eval` or relevant flake check while developing; run `nix flake check -L` before claiming repo-wide validation. Use `nix fmt -L` for formatting if available.
- Keep `README.md` flake-only and update public usage examples when outputs change, following root `AGENTS.md`.
- Limit searches to affected outputs, avoid repeated full-repo discovery, and return changed paths, checks run, and any unverified behavior. Do not create polling loops or extra agent runs without a task-specific reason.
