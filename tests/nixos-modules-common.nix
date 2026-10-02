# Shared helpers for the NixOS module tests (tests/nixos-modules.nix and
# tests/nixos-modules-instantiate.nix).
{
  inputs,
  lib,
}: rec {
  # The named set exactly as flake.nix exports it.
  named = import ../modules/nixos/modules.nix;

  # Smallest NixOS config that instantiates without a bootloader or root
  # filesystem. x86_64-linux regardless of the evaluating system: these are
  # eval-only, and seven's cluster hosts are x86_64-linux.
  base = {
    boot.isContainer = true;
    nixpkgs.hostPlatform = "x86_64-linux";
    system.stateVersion = "26.05";
  };

  # A NixOS system with the `default` aggregator plus `modules`.
  eval = modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [base ../modules/nixos] ++ modules;
    };

  # Messages of the assertions that fail — `[]` when the config is accepted.
  failedAssertions = config:
    map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
}
