{
  description = "My personal NUR repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.05-darwin";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-iter = {
      url = "github:DeterminateSystems/flake-iter";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
    flake-root.url = "github:srid/flake-root";
    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    just-flake = {
      url = "github:juspay/just-flake";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      # inputs.flake-utils.inputs.systems.follows = "systems";
    };
    systems.url = "github:nix-systems/default";
    treefmt = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    flake-parts,
    systems,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = import systems;

      # Import our flake modules
      imports = [
        # expose flake-parts modules for consumers
        ./modules/flake-parts

        # dogfood our own flake-parts modules
        (import ./modules/flake-parts/all.nix {jackpkgsInputs = inputs;})
      ];

      perSystem = {
        system,
        pkgs,
        lib,
        config,
        ...
      }: let
        jackLib = import ./lib {inherit pkgs;};
        allPackages = {
          csharpier = pkgs.callPackage ./pkgs/csharpier {};
          docfx = pkgs.callPackage ./pkgs/docfx {};
          epub2tts = pkgs.callPackage ./pkgs/epub2tts {};
          lean = pkgs.callPackage ./pkgs/lean {};
          nbstripout = pkgs.callPackage ./pkgs/nbstripout {};
          roon-server = pkgs.callPackage ./pkgs/roon-server {};
          tod = pkgs.callPackage ./pkgs/tod {};
        };
        platformFilteredPackages = jackLib.filterByPlatforms system allPackages;
      in {
        # Make jackLib and platformFilteredPackages available for devShell
        _module.args.jackpkgs =
          {
            lib = jackLib;
            modules = import ./modules;
            homeManagerModules = import ./modules/home-manager;
            overlays = import ./overlays;
          }
          // platformFilteredPackages;

        packages =
          lib.filterAttrs (
            _: v:
              lib.isDerivation v
              && !(v.meta.broken or false)
              && (v.meta.license.free or true)
          )
          platformFilteredPackages;

        devShells.default = pkgs.mkShell {
          inputsFrom = [
            config.jackpkgs.outputs.devShell
          ];
          packages = [
          ];
        };
      };

      flake = {
        # Expose overlays for backward compatibility
        overlays.default = import ./overlay.nix;

        # Expose lib for backward compatibility
        lib = inputs.nixpkgs.lib.extend (
          final: prev:
            import ./lib {pkgs = inputs.nixpkgs.legacyPackages.${builtins.head (import inputs.systems)};}
        );

        # Expose just templates
        templates = {
          just = {
            path = ./templates/default;
            description = "just-flake template";
          };
        };
      };
    };
}
