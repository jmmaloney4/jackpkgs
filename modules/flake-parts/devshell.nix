{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.shell;
in {
  imports = [
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.shell = {
      enable = mkEnableOption "jackpkgs-devshell" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.shell = {
        inputsFrom = mkOption {
          type = types.listOf types.package;
          default = [];
          description = "Additional devShell fragments to include via inputsFrom.";
        };
        packages = mkOption {
          type = types.listOf types.package;
          default = [];
          description = "Additional packages to include in the composed devShell.";
        };
      };
      options.jackpkgs.outputs.devShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Output devShell to include in `inputsFrom`.";
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
      pcfg = config.jackpkgs.shell;
    in {
      jackpkgs.outputs.devShell = pkgs.mkShell {
        inputsFrom =
          [
            config.just-flake.outputs.devShell
            config.flake-root.devShell
            config.pre-commit.devShell
            config.treefmt.build.devShell
          ]
          ++ pcfg.inputsFrom;
        packages = pcfg.packages;
      };
    };
  };
}
