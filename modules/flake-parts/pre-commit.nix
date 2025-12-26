{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf attrByPath;
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
          default = pkgs.nbstripout;
          defaultText = "pkgs.nbstripout";
          description = "nbstripout package to use.";
        };
        mypyPackage = mkOption {
          type = types.package;
          default = let
            pythonDefaultEnv =
              attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;
          in
            if pythonDefaultEnv != null
            then pythonDefaultEnv
            else pkgs.mypy;
          defaultText = "`jackpkgs.python.environments.default` (when defined) or `pkgs.mypy`";
          description = "mypy package to use.";
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
          package = sysCfg.nbstripoutPackage;
          entry = "${lib.getExe sysCfg.nbstripoutPackage}";
          files = "\\.ipynb$";
        };
        settings.hooks.mypy = {
          enable = true;
          package = sysCfg.mypyPackage;
          entry = "${lib.getExe sysCfg.mypyPackage}";
          files = "\\.py$";
          excludes = ["^nix/" "/node_modules/" "/dist/" "/__pycache__/"];
        };
      };
    };
  };
}
