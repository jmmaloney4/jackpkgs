{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.just; # top-level enable
in {
  imports = [
    inputs.pre-commit-hooks.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (inputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.fmt = {
      enable = mkEnableOption "jackpkgs-pre-commit" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.pre-commit = {
      };
    });
  };

  config = mkIf cfg.enable {
    # Contribute per-system config as a function (this is the correct place for a function)
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      pcfg = config.jackpkgs.pre-commit; # per-system config scope
    in {
    #   pre-commit = {
    #     check.enable = true;
    #     settings.hooks.treefmt.enable = true;
    #     settings.hooks.treefmt.package = config.treefmt.build.wrapper;
    #   };
    };
  };
}
