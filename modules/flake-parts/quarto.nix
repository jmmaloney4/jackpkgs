{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.quarto;
in {
  imports = [
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.quarto = {
      enable = mkEnableOption "jackpkgs-quarto" // {default = true;};

      sites = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Quarto sites to build.";
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.quartoDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Quarto devShell fragment to include in `inputsFrom`.";
      };

      options.jackpkgs.quarto = {
        pythonEnv = mkOption {
          type = types.package;
          default = pkgs.python3Packages.python;
          description = "Python environment to use for Quarto.";
        };
      };
    });
  };

  config =
    mkIf cfg.enable
    {
      perSystem = {
        pkgs,
        lib,
        config,
        ...
      }: {
        jackpkgs.outputs.quartoDevShell = pkgs.mkShell {
          packages = with pkgs; [
          ];
        };

        # Contribute this fragment to the composed devshell
        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.quartoDevShell
        ];
      };
    };
}
