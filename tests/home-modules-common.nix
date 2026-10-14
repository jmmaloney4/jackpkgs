# Shared helpers for the Home Manager module tests (tests/home-modules.nix and
# tests/home-modules-instantiate.nix).
{
  inputs,
  lib,
}: rec {
  # The named set exactly as flake.nix exports it.
  named = import ../modules/home-manager/modules.nix;

  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;

  base = {
    home.username = "alice";
    home.homeDirectory = "/home/alice";
    home.stateVersion = "26.05";
  };

  # A standalone Home Manager configuration with the `default` aggregator
  # plus `modules`.
  eval = modules:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [base (import ../modules/home-manager)] ++ modules;
    };

  identity = {
    userName = "Alice Example";
    userEmail = "alice@example.com";
  };
}
