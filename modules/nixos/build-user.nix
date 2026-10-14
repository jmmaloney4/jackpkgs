# NixOS half of jackpkgs.build-user (ADR-051). The option surface and account wiring
# live in ../common/build-user.nix; this adds the Home Manager NixOS module that the
# wiring writes `home-manager.users.*` into, so importing
# `nixosModules.build-user` alone evaluates (it does not depend on also importing
# `nixosModules.profile`).
#
# A function of the flake `inputs` (applied in ./modules.nix). Importing is
# inert: the common module is gated on `jackpkgs.build-user.enable`.
inputs: {
  # A key makes the module dedupe against `default` and the other named
  # outputs that import the same Home Manager module.
  key = "jackpkgs/nixos/build-user";

  imports = [
    ../common/build-user.nix
    inputs.home-manager.nixosModules.home-manager
  ];
}
