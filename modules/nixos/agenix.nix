# jackpkgs.agenix — agenix wired for host-key decryption (ADR-051 OD-C, option
# a1: jackpkgs owns the glue).
#
# A function of the flake `inputs`, applied at the flake boundary
# (modules/nixos/modules.nix), so a consumer imports `nixosModules.agenix` and
# gets upstream agenix plus this glue with no `specialArgs` and no per-consumer
# input wiring. Promoted from garden `nixfiles/modules/nixos/agenix.nix`.
#
# Importing is inert: upstream agenix declares options only, and the one value
# this sets is gated on `jackpkgs.agenix.enable`. Secrets themselves
# (`age.secrets.*`) stay with the consumer.
#
# Opinion consumers inherit: secrets decrypt with the host's ed25519 SSH key.
# It is `mkDefault`, so a host with another identity just sets
# `age.identityPaths`.
inputs: {
  config,
  lib,
  ...
}: {
  # A `key` makes the module dedupe when a consumer imports `default` and
  # `agenix` together; an anonymous wrapper would declare agenix's options twice.
  key = "jackpkgs/nixos/agenix";

  imports = [inputs.agenix.nixosModules.default];

  options.jackpkgs.agenix.enable = lib.mkEnableOption "agenix secret decryption with the host SSH ed25519 key";

  config = lib.mkIf config.jackpkgs.agenix.enable {
    age.identityPaths = lib.mkDefault ["/etc/ssh/ssh_host_ed25519_key"];
  };
}
