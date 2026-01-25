# Module that provides jackpkgs.pkgs option for consumer-provided nixpkgs instances
#
# This allows consumers to use overlayed nixpkgs with jackpkgs modules:
#
#   perSystem = { system, ... }: let
#     overlayedPkgs = import inputs.nixpkgs {
#       inherit system;
#       overlays = [ ... ];
#     };
#   in {
#     _module.args.pkgs = overlayedPkgs;
#     jackpkgs.pkgs = overlayedPkgs;
#   };
#
# All jackpkgs module package defaults reference config.jackpkgs.pkgs,
# so setting this option propagates overlays to all package defaults.
{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: {
  options = let
    inherit (lib) types mkOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.pkgs = mkOption {
        type = types.pkgs;
        default = pkgs;
        defaultText = "pkgs";
        description = ''
          The nixpkgs instance to use for all jackpkgs modules.

          Set this to your overlayed nixpkgs to propagate overlays to all
          jackpkgs package defaults. When not set, defaults to the standard
          pkgs from flake-parts.

          Example:
            perSystem = { system, ... }: let
              overlayedPkgs = import inputs.nixpkgs {
                inherit system;
                overlays = [ myOverlay ];
              };
            in {
              _module.args.pkgs = overlayedPkgs;
              jackpkgs.pkgs = overlayedPkgs;
            };
        '';
      };
    });
  };
}
