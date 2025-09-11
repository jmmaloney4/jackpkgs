{
  description = "My personal NUR repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.05-darwin";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    just-flake = {
      url = "github:juspay/just-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "i686-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "aarch64-linux"
        "armv6l-linux"
        "armv7l-linux"
      ];

      # Import our flake modules
      imports = [
        ./modules/flake-parts
      ];

      perSystem = {
        system,
        pkgs,
        lib,
        config,
        ...
      }: {
        # Import our packages using the existing structure
        _module.args.jackpkgs = import ./default.nix {inherit pkgs;};

        packages = lib.filterAttrs (_: v: lib.isDerivation v) config._module.args.jackpkgs;

        # Legacy compatibility - expose the full jackpkgs set
        legacyPackages = config._module.args.jackpkgs;
      };

      flake = {
        # Expose overlays for backward compatibility
        overlays.default = import ./overlay.nix;

        # Expose lib for backward compatibility
        lib = inputs.nixpkgs.lib.extend (
          final: prev:
            import ./lib {pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;}
        );

        # Expose just templates
        templates = {
          just = {
            path = ./modules/flake-parts/justfile-template;
            description = "just-flake template";
          };
        };
      };
    };
}
