{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pre-commit;
in {
  imports = [
    jackpkgsInputs.pre-commit-hooks.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pre-commit = {
      enable = mkEnableOption "jackpkgs-pre-commit" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.pre-commit = {
        treefmtPackage = mkOption {
          type = types.package;
          default = config.treefmt.build.wrapper;
          defaultText = "config.treefmt.build.wrapper";
          description = "treefmt package to use.";
        };
        nbstripoutPackage = mkOption {
          type = types.package;
          default = pkgs.callPackage ../../pkgs/nbstripout {};
          defaultText = "pkgs.callPackage ../../pkgs/nbstripout {}";
          description = "Self-contained nbstripout package with no PATH pollution.";
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      sysCfg = config.jackpkgs.pre-commit;
    in {
      pre-commit = {
        check.enable = true;
        settings.hooks.treefmt.enable = true;
        settings.hooks.treefmt.package = sysCfg.treefmtPackage;
        settings.hooks.nbstripout = {
          enable = true;
          entry = "${lib.getExe sysCfg.nbstripoutPackage}";
          files = "\\.ipynb$";
        };
      };
    };
  };
}
