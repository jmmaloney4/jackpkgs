{ inputs, ... }:
{
  perSystem = { system, pkgs, lib, ... }: {
    # This module ensures packages are available per-system
    # The actual package definitions are imported via _module.args.jackpkgs
  };

  # Note: Cross-system package access is handled through legacyPackages
  # in the main flake configuration

  flake = {
    # Re-export the legacyPackages for backward compatibility
    legacyPackages = inputs.nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "i686-linux"
      "x86_64-darwin"
      "aarch64-darwin"
      "aarch64-linux"
      "armv6l-linux"
      "armv7l-linux"
    ] (system:
      import ../../default.nix {
        pkgs = inputs.nixpkgs.legacyPackages.${system};
      }
    );
  };
}
