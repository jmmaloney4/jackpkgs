# jackpkgs.determinate — Determinate Nix (ADR-051 Decision 3, cheap input).
#
# A function of the flake `inputs`, applied at the flake boundary
# (modules/nixos/modules.nix), like ./agenix.nix. Promoted from the
# `determinate.enable = true` line in garden's `nixfiles/modules/nixos/default.nix`.
#
# TRAP this module exists to contain: upstream `determinate.enable` DEFAULTS TO
# TRUE. Merely importing `inputs.determinate-nix.nixosModules.default` replaces
# `nix.package` and the nixpkgs registry entry on every host. Here the upstream
# switch is driven from `jackpkgs.determinate.enable` unconditionally (at
# `mkDefault` priority, so the consumer can still override), which restores the
# ADR-051 rule that importing is inert.
#
# Garden's companion settings (`nix.gc.automatic`, `nix.optimise.automatic`,
# `nix.nrBuildUsers`) are host taste and stay in the consumer.
inputs: {
  config,
  lib,
  ...
}: {
  key = "jackpkgs/nixos/determinate";

  imports = [inputs.determinate-nix.nixosModules.default];

  options.jackpkgs.determinate.enable = lib.mkEnableOption "Determinate Nix (nix.package, registry and daemon settings from the determinate-nix flake)";

  config.determinate.enable = lib.mkDefault config.jackpkgs.determinate.enable;
}
