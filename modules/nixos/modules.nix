# The named NixOS module set (ADR-051 Decision 1): output name -> module file.
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
# evaluates on its own.
import ../common/modules.nix
// {
  disks = ./disks.nix;
  docker = ./docker.nix;
  nix = ./nix.nix;
  tailscale = ./tailscale.nix;
  zenith = ./zenith.nix;
}
