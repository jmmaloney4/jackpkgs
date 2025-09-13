{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.fmt;
in {
  imports = [
    jackpkgsInputs.flake-root.flakeModule
    jackpkgsInputs.treefmt.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.fmt = {
      enable = mkEnableOption "jackpkgs-treefmt" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.fmt = {
        treefmtPackage = mkOption {
          type = types.package;
          default = pkgs.treefmt;
          defaultText = "pkgs.treefmt";
          description = "treefmt package to use.";
        };
        projectRootFile = mkOption {
          type = types.str;
          default = config.flake-root.projectRootFile;
          defaultText = "config.flake-root.projectRootFile";
          description = "Project root file to use.";
        };
        excludes = mkOption {
          type = types.listOf types.str;
          default = ["**/node_modules/**" "**/dist/**"];
          description = "Excludes for treefmt.";
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
      pcfg = config.jackpkgs.fmt;
    in {
      formatter = lib.mkDefault config.treefmt.build.wrapper;
      treefmt.config = let
        excludes = pcfg.excludes;
      in {
        inherit (pcfg) projectRootFile;
        package = pkgs.treefmt;
        # alejandra formats nix code
        programs.alejandra = {
          enable = true;
          inherit excludes;
        };
        # biome lints and formats js/ts code
        programs.biome = {
          enable = true;
          inherit excludes;
        };
        # latex
        programs.latexindent = {
          enable = true;
          inherit excludes;
        };
        # just use prettier for json files
        programs.prettier = {
          enable = true;
          inherit excludes;
          includes = ["*.json"];
        };
        # ruff lints and formats python code
        programs.ruff-check = {
          enable = true;
          inherit excludes;
        };
        programs.ruff-format = {
          enable = true;
          inherit excludes;
        };
        # rust obv
        programs.rustfmt = {
          enable = true;
          inherit excludes;
        };
        # yaml
        programs.yamlfmt = {
          enable = true;
          inherit excludes;
        };
      };
    };
  };
}
