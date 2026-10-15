# NixOS half of jackpkgs.operator (ADR-051). The option surface and account wiring
# live in ../common/operator.nix; this adds the Home Manager NixOS module that the
# wiring writes `home-manager.users.*` into, so importing
# `nixosModules.operator` alone evaluates (it does not depend on also importing
# `nixosModules.profile`).
#
# A function of the flake `inputs` (applied in ./modules.nix). Importing is
# inert: the common module is gated on `jackpkgs.operator.enable`.
inputs: {
  # A key makes the module dedupe against `default` and the other named
  # outputs that import the same Home Manager module.
  key = "jackpkgs/nixos/operator";

  imports = [
    ../common/operator.nix
    inputs.home-manager.nixosModules.home-manager
  ];
}
