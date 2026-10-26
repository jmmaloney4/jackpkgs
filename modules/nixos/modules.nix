# The named NixOS module set (ADR-051 Decision 1): output name -> module.
#
# A function of the flake `inputs`: most entries are paths, but the
# cheap-input glue (`agenix`, `determinate`) needs the pinned upstream modules,
# so those files are applied to `inputs` here, at the flake boundary.
#
# The single source of truth for both `flake.nixosModules.<name>` and the
# `default` aggregator (./default.nix), so a module cannot be exported by
# name and silently missing from `default`, or vice versa.
#
# Built as the platform-agnostic set (../common/modules.nix, also exported as
# `darwinModules`) overlaid with the NixOS-only modules. Where a concern has a
# NixOS-only half (`nix`, `tailscale`), the NixOS name points at that half,
# which imports the platform-agnostic file from ../common. Each file declares
# its own cross-module dependencies through `imports`, so every named output
# evaluates on its own. The input-backed entries carry a module `key`, so
# importing `default` plus a named output still declares their options once.
inputs:
import ../common/modules.nix
// {
  agenix = import ./agenix.nix inputs;
  build-user = import ./build-user.nix inputs;
  cache-target-pruner = ./cache-target-pruner.nix;
  claude-managed-settings = ./claude-managed-settings.nix;
  determinate = import ./determinate.nix inputs;
  disks = ./disks.nix;
  docker = ./docker.nix;
  nix = ./nix.nix;
  operator = import ./operator.nix inputs;
  profile = import ./profile.nix inputs;
  repo-sync = ./repo-sync.nix;
  tailscale = ./tailscale.nix;
  zenith = ./zenith.nix;
}
