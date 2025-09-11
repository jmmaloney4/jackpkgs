{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.just;
in {
  imports = [
    inputs.just-flake.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
  in {
    jackpkgs.just.enable = mkEnableOption "jackpkgs-just-flake";
  };

  config = mkIf cfg.enable {
    perSystem = {system, ...}: {
      just-flake = lib.mkDefault {
        features = {
          treefmt.enable = true;
          rust.enable = true;
          hello = {
            enable = true;
            justfile = ''
              hello:
              echo Hello Jackpkgs!
            '';
          };
        };
      };
    };
  };
}
