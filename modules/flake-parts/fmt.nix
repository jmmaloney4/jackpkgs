{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.fmt;
in {
  imports = [
    inputs.treefmt.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (inputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.fmt = {
      enable = mkEnableOption "jackpkgs-treefmt" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.fmt = {
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
      pcfg = config.jackpkgs.fmt;
    in {
      formatter = lib.mkDefault config.treefmt.build.wrapper;
      treefmt.config = let
        excludes = ["**/node_modules/**" "**/dist/**"];
      in {
        inherit (config.flake-root) projectRootFile;
        package = pkgs.treefmt;
        programs.alejandra = {
          enable = true;
          inherit excludes;
        };
        programs.ruff-check = {
          enable = true;
          inherit excludes;
        };
        programs.ruff-format = {
          enable = true;
          inherit excludes;
        };
        programs.biome = {
          enable = true;
          inherit excludes;
        };
        programs.prettier = {
          enable = true;
          inherit excludes;
          includes = ["*.json"];
        };
        programs.rustfmt = {
          enable = true;
          inherit excludes;
        };
        programs.yamlfmt = {
          enable = true;
          inherit excludes;
        };
      };
    };
  };
}
