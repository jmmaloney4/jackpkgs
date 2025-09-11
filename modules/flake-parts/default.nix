{ inputs, ... }:
{
  imports = [
    ./packages.nix
    ./overlays.nix
    ./home-manager.nix
    ./lib.nix
  ];

  flake = {
    # Consolidate all flakeModules into a single definition
    flakeModules = {
      # Import all the module definitions
      overlays = {
        flake = {
          overlays = import ../../overlays;
        };
      };

      lib = {
        flake = {
          lib = inputs.nixpkgs.lib.extend (final: prev:
            import ../../lib { pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux; }
          );
        };
      };

      homeManager = {
        imports = [
          inputs.home-manager.flakeModules.home-manager
          ../../home-manager
        ];
      };
    };
  };
}
